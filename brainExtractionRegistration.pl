#!/usr/bin/perl -w

use strict;
use File::Basename;
use File::Copy;
use File::Path;
use Getopt::Long;


my $usage = qq{

  $0
     --input
     --template
     --template-brain-mask
     --output-root
     [options]

  
  Customizable implementation of antsBrainExtraction.sh, for developing BE algorithm.

  The basic stages are:
     
    1. Optional preprocessing to truncate outlier intensity and bias-correct with N4

    2. Rigid and affine registration to the template.

    3. Regularized deformable registration with SyN and CC metric.

    4. Fine-scale registration with SyN, optionally using the Laplacian to 
       boost edge alignment. 

  Registration masks may be used to improve alignment. Either a single mask can be used
  for all stages, or separate masks can be used for the early and late stages. A tighter
  mask for the finer-scale deformable registration might help in some cases.

  Required args:

     --input
       Head image to be brain extracted.

     --template
       Template, assumed to be the same modality (use CC as the deformable metric).

     --template-brain-mask
       Brain mask (or probability image).

     --output-root
       Path and basename of output.
  
  Options:

     --template-reg-mask
       Registration mask applied to all stages of the registration.

     --template-reg-masks
       List of two masks, one for the affine / initial SyN registration, and one for 
       the finer scale iterations.

     --bias-correct
       Winsorize outliers and run N4 on the input image (default = 1).

     --laplacian-sigma
       Computes Laplacian on the template and input image, which is used in the registration. A value of 0
       means the Laplacian is not used. Use ImageMath to test varying sigma, you probably want something in 
       the range 1 to 2 (default = 0).

     --seg-priors
       Segmentation priors to be warped to the subject space after registration. Priors must be numbered 
       sequentially from 1 and end with number.nii.gz. Eg, prior1.nii.gz, prior2.nii.gz ... or prior01.nii.gz.
    
     --float 
       Use float precision (default = 0).

     --quick
       Reduces iterations to produce a faster result (default = 0).

     --save-transforms
       Save the transforms from registration, useful for debugging failures (default = 0).

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
my ($inputHead, $template, $templateBrainMask, $outputRoot);

# Optional args have defaults
my $useTemplateRegMask = 0;
my @templateRegMasks = ();
# Used for affine and early deformable registration
my $templateAffineRegMask = "";
# Used for the fine-scale registration stages
my $templateDeformableRegMask = "";
my $doN4 = 1;
my $laplacianSigma = 0;
my @segPriors = ();
my $useFloatPrecision = 0;
my $quick = 0;
my $saveTransforms = 0;

GetOptions ("input=s" => \$inputHead,
	    "output-root=s" => \$outputRoot,
            "template=s" => \$template,
	    "template-brain-mask=s" => \$templateBrainMask,
	    "template-reg-mask=s" => \@templateRegMasks,
	    "template-reg-masks=s{1,}" => \@templateRegMasks,
	    "bias-correct=i" => \$doN4,
	    "laplacian-sigma=f" => \$laplacianSigma,
	    "seg-priors=s{1,}" => \@segPriors,
	    "float=i" => \$useFloatPrecision,
            "quick=i" => \$quick,
            "save-transforms=i" => \$saveTransforms
    )
    or die("Error in command line arguments\n");

my $useLaplacian = ($laplacianSigma > 0);

if (scalar(@templateRegMasks) > 0) {
    $useTemplateRegMask = 1;
    
    $templateAffineRegMask = $templateRegMasks[0];
    $templateDeformableRegMask = $templateRegMasks[0];
    
    if (scalar(@templateRegMasks) > 1) {
	$templateDeformableRegMask = $templateRegMasks[1];
    }
}

my ($outputFileRoot,$outputDir) = fileparse($outputRoot);

if (! -d $outputDir ) {
  mkpath($outputDir, {verbose => 0, mode => 0775}) or die "Cannot create output directory $outputDir\n\t";
}

# Set to 1 to delete intermediate files after we're done
my $cleanup=0;

# Directory for temporary files that is deleted later if $cleanup
my $tmpDir = "";

my $tmpDirBaseName = "${outputFileRoot}beReg";

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

if ($doN4) {
    my $truncateMask = "${tmpDir}/intensityMask.nii.gz";
    
    # Truncate intensity idea copied from antsBrainExtraction.sh, useful for T1, not sure about other modalities
    # Attempt to make quantiles insensitive to amount of background
    system("${antsPath}ImageMath 3 $truncateMask Normalize $inputHead 1");
    system("${antsPath}ThresholdImage 3 $truncateMask $truncateMask 0.5 Inf");
    system("${antsPath}ImageMath 3 $headImage TruncateImageIntensity $inputHead -1.0 0.995 256 $truncateMask");
    system("${antsPath}N4BiasFieldCorrection -d 3 -i $headImage -s 4 -c [50x50x50x50,0.0000001] -b [200] -o $headImage --verbose 1");
}
else {
    copy($inputHead, $headImage);
}


# Get initial moving transform to template
my $antsAffInitRes = "4 4 4";
# in mm
my $antsAffInitSmooth = "3";

my $downsampleTemplate = "${tmpDir}/templateDownsample.nii.gz";
my $downsampleHeadImage = "${tmpDir}/headDownsample.nii.gz";
my $downsampleRegMask = "${tmpDir}/templateRegMaskDownsample.nii.gz";

system("${antsPath}SmoothImage 3 $template $antsAffInitSmooth ${tmpDir}/templateSmooth.nii.gz  1");
system("${antsPath}SmoothImage 3 $headImage $antsAffInitSmooth ${tmpDir}/headSmooth.nii.gz 1");

system("${antsPath}ResampleImageBySpacing 3 ${tmpDir}/templateSmooth.nii.gz $downsampleTemplate $antsAffInitRes 0");
system("${antsPath}ResampleImageBySpacing 3 ${tmpDir}/headSmooth.nii.gz $downsampleHeadImage $antsAffInitRes 0");

my $initialAffine = "${tmpDir}/initialAffine.mat";

# -s [ searchFactor, arcFraction ]
# searchFactor = step size
# arcFraction = fraction of arc to search 1 = +/- 180 degrees, 0.5 = +/- 90 degrees
#
my $antsAICmd = "${antsPath}antsAI -d 3 -v 1 -m Mattes[$downsampleTemplate, $downsampleHeadImage, 32, Regular, 0.2] -t Rigid[0.1] -s [18, 0.1] -c 10 -g [40, 40x40x40] -o $initialAffine";

if ($useTemplateRegMask) {

    system("${antsPath}ResampleImageBySpacing 3 $templateAffineRegMask $downsampleRegMask $antsAffInitRes 0 0 1");

    $antsAICmd = "$antsAICmd -x $downsampleRegMask";
    
}

print "\n--- ANTs AI ---\n${antsAICmd}\n---\n";

system($antsAICmd);

my $warpPrefix = "${tmpDir}/headToTemplate";

my $affineRegMaskString = "";

if ($useTemplateRegMask) {
    $affineRegMaskString = "-x $templateAffineRegMask";
}

my $histogramMatch = 1;

# Don't histogram match if we are using Laplacian, it will mess up edge contrasts
if ($useLaplacian) {
    $histogramMatch = 0;
}


# Registration overview
#
# 1. Standard rigid + affine with fixed = template
# 2. Regularized SyN with CC, using structural image only
# 3. Fine scale refinement using structural image + optional Laplacian
#

my $rigidIts = "100x100x50x0";

my $affineIts = "100x100x50x0";

my $regAffineCmd = "${antsPath}antsRegistration -d 3 -u $histogramMatch -w [0, 0.999] --verbose --float $useFloatPrecision -o $warpPrefix -r $initialAffine -t Rigid[0.1] -m Mattes[$template, $headImage, 1, 32, Regular, 0.25] -f 6x4x2x1 -s 3x2x1x0mm -c [${rigidIts},1e-7,10] $affineRegMaskString -t Affine[0.1] -m Mattes[$template, $headImage, 1, 32, Regular, 0.25] -f 6x4x2x1 -s 3x2x1x0mm -c [${affineIts},1e-7,10] $affineRegMaskString";


# Larger means slower. More robust in the brain but we care most about the edges, which change on a fine scale
# 2 or 3 seem to work best, but maybe larger might be better at the early stages
my $ccRadius = 3;

my $regSyNMetric = "-m CC[${template},${headImage}, 1, ${ccRadius}]";

# Do coarse-level SyN with broader (affine) mask, to get skull somewhat aligned
# Don't use Laplacian at this resolution
my $regCmd = "$regAffineCmd -t SyN[0.2,3,1] $regSyNMetric -c [30x40x0,1e-7,10] -f 6x4x1 -s 3x2x0mm";

if ($useTemplateRegMask) {
    $regCmd = "$regCmd -x $templateAffineRegMask";
}

# Finer scale optionally with Laplacian
#
my $intermediateSyNIts = "20x0";

if ($useLaplacian) {

    my $templateLaplacian = "${tmpDir}/templateLaplacian.nii.gz";
    my $headLaplacian = "${tmpDir}/headLaplacian.nii.gz";

    system("${antsPath}ImageMath 3 $templateLaplacian Laplacian $template $laplacianSigma 1");
    system("${antsPath}ImageMath 3 $headLaplacian Laplacian $headImage $laplacianSigma 1");
    
    $regSyNMetric = "-m CC[${template},${headImage}, 0.5, ${ccRadius}] -m CC[${templateLaplacian},${headLaplacian}, 0.5, ${ccRadius}]";
   
    $regCmd = "$regCmd -t SyN[0.2,3,1] $regSyNMetric -c [${intermediateSyNIts},1e-7,10] -f 3x1 -s 1.5x0mm";
    
    # Use deformable mask here, which may be tighter to the brain
    if ($useTemplateRegMask) {
        $regCmd = "$regCmd -x $templateDeformableRegMask";
    }
    
    my $fineScaleSyNIts = "25x0";
    
    if ($quick) {
        $fineScaleSyNIts = "10x0";
    }

    # Alternative idea, use MI for the Laplacian.
    # Since we have two metrics, use larger step size + less smoothing (Laplacian is fairly smooth)
    $regCmd = "$regCmd -t SyN[0.2,3,0] $regSyNMetric -c [${fineScaleSyNIts},1e-7,10] -f 2x1 -s 0.5x0mm";

    if ($useTemplateRegMask) {
        $regCmd = "$regCmd -x $templateDeformableRegMask";
    }


}
else {
    
    $regCmd = "$regCmd -t SyN[0.2,3,1] $regSyNMetric -c [${intermediateSyNIts},1e-7,10] -f 3x1 -s 1.5x0mm";
    
    # Use deformable mask here, which may be tighter to the brain
    if ($useTemplateRegMask) {
        $regCmd = "$regCmd -x $templateDeformableRegMask";
    }
    
    my $fineScaleSyNIts = "10x15x0";
    
    if ($quick) {
        $fineScaleSyNIts = "5x5x0";
    }

    # Without Laplacian, take smaller steps
    # Try to extend capture range with 1mm smoothing, but this can also smooth out boundaries
    # Some cases do better with minimal smoothing

    $regCmd = "$regCmd -t SyN[0.1,3,0] $regSyNMetric -c [${fineScaleSyNIts},1e-7,10] -f 2x2x1 -s 1x0.5x0mm";

    if ($useTemplateRegMask) {
        $regCmd = "$regCmd -x $templateDeformableRegMask";
    }
    
}



print "\n--- Registration ---\n${regCmd}\n---\n";

system($regCmd);

my $brainMaskFromReg = "${tmpDir}/brainMask.nii.gz";

# Warp mask with Gaussian interpolation
system("${antsPath}antsApplyTransforms -d 3 -r $headImage -i $templateBrainMask -o $brainMaskFromReg -t [${warpPrefix}0GenericAffine.mat,1] -t ${warpPrefix}1InverseWarp.nii.gz -n Gaussian --verbose --float $useFloatPrecision");

system("${antsPath}ThresholdImage 3 $brainMaskFromReg $brainMaskFromReg 0.5 Inf");

copy($brainMaskFromReg, "${outputRoot}BrainMask.nii.gz");

# If we have priors, warp those too
if (scalar(@segPriors) > 0) {
    foreach my $prior (@segPriors) {
	# Assume priors are named prior[0-9]+.nii.gz
	$prior =~ m/([0-9]+).nii.gz/;

	my $priorClass = $1;

	system("${antsPath}antsApplyTransforms -d 3 -i $prior -r $headImage -t [${warpPrefix}0GenericAffine.mat, 1] -t ${warpPrefix}1InverseWarp.nii.gz -n Gaussian -o ${outputRoot}SegPrior${priorClass}.nii.gz --float $useFloatPrecision --verbose");
    }

}

# Optionally save transforms
if ($saveTransforms) {
    copy($initialAffine, "${outputRoot}ToTemplateInitialTransform.mat");
    copy("${warpPrefix}0GenericAffine.mat", "${outputRoot}ToTemplate0GenericAffine.mat");
    copy("${warpPrefix}1Warp.nii.gz", "${outputRoot}ToTemplate1Warp.nii.gz");
    copy("${warpPrefix}1InverseWarp.nii.gz", "${outputRoot}ToTemplate1InverseWarp.nii.gz");
}


# cleanup

if ($cleanup) {
    system("rm ${tmpDir}/*");
    system("rmdir ${tmpDir}");
}

