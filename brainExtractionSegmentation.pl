#!/usr/bin/perl -w

use strict;
use File::Basename;
use File::Copy;
use File::Path;
use Getopt::Long;


my $usage = qq{

  $0
     --input
     --initial-brain-mask
     --output-root
     [options]

  
  Does segmentation to improve brain mask from registration. 

  A minimal brain mask is defined by the initial brain mask (usually from registration), which
  can optionally be eroded by this script. Voxels within the minimal mask are always included in the
  final mask.

  The initial brain mask is dilated and the voxels within the dilated mask but not in the minimal mask 
  may be included in the final output. 


  Required args:

     --input
       T1 head image to be brain extracted.

     --initial-brain-mask
       Initial guess of the brain mask, usually from registration.

     --output-root
       Path and basename of output.
  
  Options:

     --erosion-radius 
       Voxel radius for erosion of the initial mask. Voxels within the eroded mask always remain within the final 
       brain mask (default = 0).

     --dilation-radius 
       Voxel radius for dilation of the initial mask. Voxels within this radius will be segmented and may be added
       to the brain mask (default = 2).

     --bias-correct
       Run N4 on the input image using the dilated brain mask (default = 1).

     --k-means-classes
       For k-means segmentation, Atropos orders the segmentation labels by order of mean intensity. Specify the
       number of classes and their identification as a hash. For example:


       --k-means-classes csf=1 gm=2 wm=3  (for T1; default)
       --k-means-classes csf=3 gm=2 wm=1  (for T2)
       --k-means-classes csf=1 gm=3 wm=2  (for FLAIR)
       --k-means-classes csf=4 gm=3 wm=2 meninges=1  (for T2, use 4 classes)
       

     --prior-spec
       Atropos prior specification, eg "Prior%02d.nii.gz", to use priors for segmentation.
       Otherwise, segmentation is with k-means. Any number of priors > 2 may be used, assuming
       (CSF, Cortex, WM) are classes (1,2,3).

     --include-classes
       The script includes or excludes WM and GM outside the minimal mask based on connectivity. This option allows
       other classes to be included. For example, with the standard ANTs six classes, one might use 
       --include-classes 4 5 6 to retain deep gray / brainstem / cerebellum. Note this can include voxels outside 
       the initial mask.

     --include-initial-classes
       Include additional classes, but only if they are within the original mask. For example if the registration
       to cerebellum is very good, you might want to include it directly, and not add voxels segmented as cerebellum
       within the dilated mask. This option is mutually exclusive with --include-classes.

     --prior-weight
       Segmentation prior weight (default 0.15). Decreasing this is not recommended if you are using mixed-tissue 
       priors (like the standard ANTs 6-classes). Increasing the value adds more weight to the prior specification.

     --mrf-weight
       MRF weighting term (default = 0.1).

     --mrf-radius
       MRF radius in 3D (default = 1x1x1).


  Requires ANTSPATH

};


if ($#ARGV < 0) {
    print $usage;
    exit 1;
}

# Get the directories containing programs we need
my ($antsPath, $sysTmpDir) = @ENV{'ANTSPATH', 'TMPDIR'};


if (!$antsPath || ! -f "${antsPath}antsRegistration") {
    die("Script requires ANTSPATH to be defined");
}

# Required args
my ($inputHead, $initialBrainMask, $outputRoot);

# Optional args have defaults
my $doN4 = 1;
my $dilationRadius = 2;
my $erosionRadius = 0;

# Set from k-means Classes or priors
my $numSegClasses = 0;

# Used for k-means only
my %kMeansClasses = ( csf => 1, gm => 2, wm => 3 );

# Need some prior weight for mixed tissue classes
my $priorWeight = 0.15;

my $priorSpec = "";
my $usePriors = 0;


my $mrfWeight=0.1;
my $mrfRadius="1x1x1";

# List of classes to add back to final mask, eg cerebellum
my @includedSegClasses = ();

# If true, mask extra classes with initial brain mask. For example, include cerebellum voxels but only if they
# are within the initial brain mask
my $maskIncludedClasses = 0;

GetOptions ("input=s" => \$inputHead,
	    "output-root=s" => \$outputRoot,
            "initial-brain-mask=s" => \$initialBrainMask,
	    "bias-correct=i" => \$doN4,
	    "dilation-radius=i" => \$dilationRadius,
	    "erosion-radius=i" => \$erosionRadius,
	    "k-means-classes=s{1,}" => \%kMeansClasses,
	    "prior-spec=s" => \$priorSpec,
	    "prior-weight=s" => \$priorWeight,
            "include-classes=i{1,}" => \@includedSegClasses,
            "include-initial-classes=i{1,}" => sub { @includedSegClasses = @_; $maskIncludedClasses = 1;},
	    "mrf-weight=f" => \$mrfWeight,
	    "mrf-radius=s" => \$mrfRadius
    )
    or die("Error in command line arguments\n");

my ($outputFileRoot,$outputDir) = fileparse($outputRoot);


if ($priorSpec) {
    $usePriors = 1;

    $numSegClasses = 0;

    my $priorImage = sprintf($priorSpec, 1);

    while (-f $priorImage) {
	$numSegClasses++;
	$priorImage = sprintf($priorSpec, $numSegClasses + 1);
    }
}
else {
    $numSegClasses = scalar(keys(%kMeansClasses));
}

if (! -d $outputDir ) {
  mkpath($outputDir, {verbose => 0, mode => 0775}) or die "Cannot create output directory $outputDir\n\t";
}

# Set to 1 to delete intermediate files after we're done
my $cleanup=1;

# Directory for temporary files that is deleted later if $cleanup
my $tmpDir = "";

my $tmpDirBaseName = "${outputFileRoot}beSeg";

if ( !($sysTmpDir && -d $sysTmpDir) ) {
    $tmpDir = $outputDir . "/${tmpDirBaseName}";
}
else {
    # Have system tmp dir
    $tmpDir = $sysTmpDir . "/${tmpDirBaseName}";
}

# Gets removed later, so check we can create this and if not, exit immediately
mkpath($tmpDir, {verbose => 0, mode => 0755}) or die "Cannot create working directory $tmpDir (maybe it exists from a previous failed run)\n\t";

# Copy of input we can work on
my $headImage = "${tmpDir}/head.nii.gz";

copy($inputHead, $headImage);


# Padding prevents dilation problems at boundaries
my $padVoxels = 10;

my $initialBrainMaskPad = "${tmpDir}/initialBrainMaskPad.nii.gz";

my $minimalBrainMask = "${tmpDir}/minimalBrainMask.nii.gz";

system("${antsPath}ImageMath 3 $headImage PadImage $headImage $padVoxels");
system("${antsPath}ImageMath 3 $initialBrainMaskPad PadImage $initialBrainMask $padVoxels");

my $brainMaskDilated = "${tmpDir}/brainMaskDilated.nii.gz";

# Dilate the initial mask, this forms the maximal possible mask
system("${antsPath}ImageMath 3 $brainMaskDilated MD $initialBrainMaskPad $dilationRadius");
system("${antsPath}CopyImageHeaderInformation $initialBrainMask $brainMaskDilated $brainMaskDilated 1 1 1");

if ($doN4) {
    # Bright voxels within initial mask can sometimes cause N4 problems, but don't want to compress actual contrast
    # After initial brain masking, most of the brightest voxels should be outside the mask
    system("${antsPath}N4BiasFieldCorrection -d 3 -i $headImage -s 3 -c [50x50x50x50,0.0000001] -b [200] -x $brainMaskDilated -o $headImage --verbose 1");
}


# Now erode the initial brain mask if we need to - this forms the minimum extent of the
# final brain mask. 
#
# Voxels that are inside the eroded initial mask are always retained.
#
# Voxels outside the eroded initial mask but inside the dilated initial mask may 
# or may not be retained based on the segmentation
#
if ($erosionRadius > 0) {
    system("${antsPath}ImageMath 3 $minimalBrainMask ME $initialBrainMaskPad $erosionRadius");
}
else {
    copy($initialBrainMaskPad, $minimalBrainMask);
}

my $brainSegRoot = "${tmpDir}/brainSeg";

my $brainSeg = "${brainSegRoot}.nii.gz";

my $atroposCmd = "${antsPath}Atropos -d 3 -o [${brainSeg},${brainSegRoot}Posteriors%d.nii.gz] -a $headImage -x $brainMaskDilated -k Gaussian -c [3,0.0] --verbose -m [${mrfWeight}, ${mrfRadius}]";

# WM and cortical GM labels - if using priors, these should be 2 and 3
my $wmLabel = 3;
my $gmLabel = 2;

if ($usePriors) {

    my ($priorSpecFile, $priorSpecDir) = fileparse($priorSpec);

    for (my $priorIndex = 0; $priorIndex < $numSegClasses; $priorIndex++) {
        my $priorImageFileName = sprintf($priorSpecFile, $priorIndex + 1);
        system("${antsPath}ImageMath 3 ${tmpDir}/${priorImageFileName} PadImage ${priorSpecDir}/${priorImageFileName} $padVoxels");           
    }
    
    $atroposCmd = "$atroposCmd -i PriorProbabilityImages[${numSegClasses},${tmpDir}/${priorSpecFile},${priorWeight}]";
}
else {  
    $atroposCmd = "$atroposCmd -i KMeans[${numSegClasses}] ";
    $wmLabel = $kMeansClasses{"wm"};
    $gmLabel = $kMeansClasses{"gm"};
}

print "\n--- Segmentation ---\n${atroposCmd}\n---\n";

system($atroposCmd);

my $wm = "${tmpDir}/wm.nii.gz";

system("${antsPath}ThresholdImage 3 $brainSeg $wm ${wmLabel} ${wmLabel}");

# Retain extra WM only if it is well connected
system("${antsPath}LabelClustersUniquely 3 $wm $wm 5000 1");
system("${antsPath}ThresholdImage 3 $wm $wm 1 Inf");

my $gmInMinMask = "${tmpDir}/gmInMinMask.nii.gz";

# GM from the min mask + WM including any extra retained
my $gmAndWM = "${tmpDir}/gmAndWM.nii.gz";

my $gm = "${tmpDir}/gm.nii.gz";

system("${antsPath}ThresholdImage 3 $brainSeg $gm $gmLabel $gmLabel");

system("${antsPath}ImageMath 3 $gmInMinMask m $gm $minimalBrainMask"); 

system("${antsPath}ImageMath 3 $gmAndWM addtozero $gmInMinMask $wm"); 

# Fill any holes arising from earlier morphology
system("${antsPath}ImageMath 3 $gmAndWM FillHoles $gmAndWM 2"); 

# Now include new GM voxels and retain if connected to GM or WM
system("${antsPath}ImageMath 3 $gmAndWM addtozero $gmAndWM $gm");

# Retain extra GM only if it is well connected 
system("${antsPath}ImageMath 3 $gmAndWM ME $gmAndWM 2");
system("${antsPath}LabelClustersUniquely 3 $gmAndWM $gmAndWM 5000 1");
system("${antsPath}ThresholdImage 3 $gmAndWM $gmAndWM 1 Inf");
system("${antsPath}ImageMath 3 $gmAndWM MD $gmAndWM 2");

# Add GM and WM to the undilated mask
my $brainMaskPad = "${tmpDir}/finalBrainMaskPad.nii.gz";

system("${antsPath}ImageMath 3 $brainMaskPad addtozero $minimalBrainMask $gmAndWM");

# Add any labels extra labels (eg cerebellum)
foreach my $includeLabel (@includedSegClasses) {
    my $includeLabelImage = "${tmpDir}/includeLabel.nii.gz";
    
    system("${antsPath}ThresholdImage 3 $brainSeg $includeLabelImage $includeLabel $includeLabel");

    if ($maskIncludedClasses) {
        system("${antsPath}ImageMath 3 $includeLabelImage m $initialBrainMaskPad $includeLabelImage");
    }
    
    system("${antsPath}ImageMath 3 $brainMaskPad addtozero $brainMaskPad $includeLabelImage");
}

system("${antsPath}ImageMath 3 $brainMaskPad FillHoles $brainMaskPad 2");

# Output N4-corrected brain 
my $extractedBrain = "${tmpDir}/extractedBrain.nii.gz";

system("${antsPath}ImageMath 3 $extractedBrain m $headImage $brainMaskPad");

# De-pad for final result
system("${antsPath}ImageMath 3 ${outputRoot}BrainMask.nii.gz PadImage $brainMaskPad -${padVoxels}");
system("${antsPath}ImageMath 3 ${outputRoot}ExtractedBrain.nii.gz PadImage $extractedBrain -${padVoxels}");

system("${antsPath}CopyImageHeaderInformation $inputHead ${outputRoot}BrainMask.nii.gz ${outputRoot}BrainMask.nii.gz 1 1 1");
system("${antsPath}CopyImageHeaderInformation $inputHead ${outputRoot}ExtractedBrain.nii.gz ${outputRoot}ExtractedBrain.nii.gz 1 1 1");


# cleanup

if ($cleanup) {
    system("rm ${tmpDir}/*");
    system("rmdir ${tmpDir}");
}

