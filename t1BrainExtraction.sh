#!/bin/bash

function checkFileExists {

  file=$1

  if [[ -f "$file" ]]; then
    return 0
  else
    echo " One or more required input files not found "
    exit 1
  fi 
}

if [[ $# -eq 0 ]]; then
  echo " 

  `basename "$0"` -a <anatomicalImage> -t <template> -m <templateMask> -o <outputRoot> [options]


  This is a wrapper for a common use case of a T1 brain extraction using registration and k-means
  segmentation.


  Required args

  -a : Anatomical head image.

  -t : Template head image.

  -m : Template brain mask (binary mask or probability image).

  -o : Output root, including path and file root.


  Options

  -b : Bias correct the input with N4 (default = 1).

  -d : Dilation radius, in voxels. Segmentation expands registration mask by no more than this amount
       (default = 2).

  -e : Erosion radius, in voxels. Segmentation reduces registration mask by no more than this amount 
       (default = 2).

  -f : Use float precision in registration (default = 0).

  -l : Laplacian sigma. Use the Laplacian with this sigma in the registration. Zero radius means
       the Laplacian is not used (default = 0).

  -q : Run quicker registration, approx 50% faster (default = 0).

  -r : Template registration mask or masks. If specified twice, the first mask is used for the initial
       alignment and the second mask for the final stages of registration.


"

exit 1

fi

binDir=`dirname "$0"`

headImage=""
outputRoot=""
template=""
templateBrainMask=""

dilationRadius=2
erosionRadius=2
doN4=1
laplacianSigma=0
runQuick=0
templateRegMasks=()
useFloat=0

while getopts "a:b:d:e:f:l:m:o:q:r:t:" OPT ; do
    case $OPT in
        a)  
            headImage=$OPTARG
            ;;
        b) 
            doN4=$OPTARG
            ;;
        d) 
            dilationRadius=$OPTARG
            ;;
        e) 
            erosionRadius=$OPTARG
            ;;
        f) 
            useFloat=$OPTARG
            ;;
        l) 
            laplacianSigma=$OPTARG
            ;;
        m)
            templateBrainMask=$OPTARG
            ;;
        o) 
            outputRoot=$OPTARG
            ;;
        q) 
            runQuick=$OPTARG
            ;;
        r) 
            templateRegMasks[${#templateRegMasks[@]}]=$OPTARG
            ;;
        t)
            template=$OPTARG
            ;;
        
        \?) 
            exit 1
            ;;
    esac
done

checkFileExists "$headImage"
checkFileExists "$template"
checkFileExists "$templateBrainMask" 


${binDir}/brainExtractionRegistration.pl \
         --input $headImage \
         --output-root $outputRoot \
         --template $template \
         --template-brain-mask $templateBrainMask \
         --template-reg-masks ${templateRegMasks[@]} \
         --bias-correct $doN4 \
         --laplacian-sigma $laplacianSigma \
         --float $useFloat \
         --quick $runQuick 

${binDir}/brainExtractionSegmentation.pl \
         --input $headImage \
         --output-root $outputRoot \
         --initial-brain-mask ${outputRoot}BrainMask.nii.gz \
         --bias-correct $doN4 \
         --erosion-radius $erosionRadius \
         --dilation-radius $dilationRadius 

