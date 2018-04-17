# altAntsBrainExtraction
Brain extraction loosely based on antsBrainExtraction.sh, but with different defaults and options

Run the scripts with no args to see usage.

Define ANTSPATH before calling the scripts.


## antsBrainExtraction.sh

The `antsBrainExtraction.sh` script does a two-stage brain extraction by first registering the input image to a template, dilating the resulting brain mask, and using segmentation to find additional voxels to include in the mask.

Here's a summary of the processing steps I made after reading through the script. The numbered steps here don't correspond to the commented step numbers in the script.


## antsBrainExtraction.sh processing overview (using default parameters)


### Preprocessing and registration

1. Winsorize outliers of head -> headWinsor

2. `N4BiasFieldCorrection` on headWinsor -> headN4

3. `antsAI` on downsampled fixed and moving images (headN4, templateHead) to find initial affine transform

4. Laplacian computation of headN4 and template

5. antsRegistration with (fixed, moving) = (templateHead, headN4) and the respective Laplacians. The Laplacian is only used for the deformable stage.

6. Warp template brain mask to subject space with Gaussian interpolation, then threshold at 0.5 -> regBrainMask

7. Dilate regBrainMask 2 voxels, and get largest component -> regBrainMaskDilated

8. Atropos with input = headN4, mask = regBrainMaskDilated, K=3 -> segImage

9. Pad segImage and regBrainMaskDilated. to avoid edge of volume morphology issues. This reversed later.


### Segmentation post-processing

Processing steps like "FillHoles" and "addtozero" are `ImageMath` operations.

10. Extract classes (1, 2, 3), from segImage -> (csfImage, gmImage, wmImage)

11. GetLargestComponent of (gmImage, wmImage) -> (gmImageLC, wmImageLC)

12. FillHoles 2 on gmImageLC -> gmFillHoles

  FillHoles 2 in ImageMath:

   a. Binarize input (threshold image at 0.5)
   b. Get distance map of thresholded input (distance to voxel in mask)
   c. Threshold distance map at 0.001
   d. Get connected components of thresholded image
   e. Set all connected components to 1
   f. Write binarized CC as output

   Basically, use distance transform to get actual closed holes (positive distance) 
   and fill them in. 

13. Multiply (gmFillHoles, gmImageLC) -> gmImageLC. This appears to undo the hole filling by computing the intersection of the image before and after filling holes.

14. Multiply wmImageLC by 3 -> wmImageLabel3

15. Erode csfImage by 10 voxels -> csfEroded

16. addtozero gmImageLC and csfEroded -> gmAndCSFEroded. There's probably not much left at this point except bits of the ventricles

17. Multiply gmAndCSFEroded by 2 -> gmImageLabel2 GM and CSF (just ventricles, probably), now have label 2.

18. addtozero wmImageLabel3 and gmImageLabel2 -> wmAndGM. If a hole in the GM was segmented as WM, it remains WM here.

19. Erode wmAndGM by 2 voxels -> gmAndWMEroded

20. GetLargestComponent on wmAndGM -> gmAndWmLC

21. Dilate gmAndWmLC by 4 voxels -> gmAndWMDilated

22. FillHoles 2 on gmAndWMDilated -> gmAndWMDilatedFillHoles

23. addtozero gmAndWMDilatedFillHoles and regBrainMask (from step 6) -> regPlusWMAndGM. Thus the mask after registration is the minimum exent of the brain mask. If registration includes too much, that can't be fixed. But if registration includes too little, we can add more with the segmentation.

24. Close regPlusWMAndGM by 5 voxels -> outputBrainMask. This smooths out bumps in the mask, but it's large enough to close the mask over the sagittal sinuses in many images.

25. Undo padding to restore original image dimensions.



## New scripts

The two scripts `brainExtractionRegistration.pl` and `brainExtractionSegmentation.pl` are designed to separately handle the registration and segmentation components of the brain extraction. This allows the user to better locate where brain extraction is working well or might be improved by altering parameters.


## antsBrainExtractionRegistration.pl processing overview

There are multiple implementation details that differ between the two scripts, but the main new features are

* Deformable registration begins with a regularized SyN step, using only the grayscale images (no Laplacian) at shrink factors 6x4. The reasoning being that the Laplacian is most useful for edge alignment at finer scales. The regularization attempts to prevent large local deformations that often pulls extra material into the brain mask region.

* Laplacian is optionally added for the finer resolution stages (shrink factors 3x2). The user can control the Laplacian sigma.

* Two registration masks can be passed, the first is used for intialization, a second mask can be used for the final stages. The idea is that it might be helpful to use a tighter registration mask to refine the registration, without undermining the global alignment.

* Segmentation priors can be warped to the subject space. This allows the segmentation to use priors.

* A --quick option does fewer iterations at fine scale, reducing processing time by approximately a factor of 2.



## antsBrainExtractionSegmentation.pl processing overview

Input to this script is the moving image and an initial brain mask (from registration or elsewhere).

The initial mask can be both eroded and dilated. The erosion of the initial mask forms the minimal brain mask. If the erosion radius is zero, then the segmentation can only expand the initial mask, as in `antsBrainExtraction.sh`. The dilation radius is the maximum distance at which to consider voxels for inclusion (2 voxels in `antsBrainExtraction.sh`).

The default erosion and dilation radii are 2 voxels. The processing steps are


* N4 of the brain using the dilated mask.

* Segmentation with k-means or priors.

* Extract WM label and use morphology to eliminate poorly-connected clusters

* Extract GM label and use morphology to eliminate poorly-connected clusters

* Add the minimal brain mask.

* If using priors, optionally add other classes eg, cerebellum, back to the mask.



## t1BrainExtraction.sh wrapper

A simple wrapper with some customizable parameters, that calls the registration and segmentation scripts in sequence and outputs a final result. The script assumes a T1 image and k-means segmentation with three classes in the default order (CSF = 1, GM = 2, WM = 3).
