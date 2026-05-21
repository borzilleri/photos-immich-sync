# Immich Behaviors

Documentation on observed behaviors in the Immich UI, for future reference and
ensuring this app implements similar behaviors that the user would expect.


## Live Photos

(or, Photos with Paired Video)

* When a live photo asset is tagged, the video component is not also tagged.
* The linked video asset does not receive descriptions applied to the main (image) asset.
* When viewing the asset in a Tag/Album view, the asset properly displays that it's a live photo.

## Asset Stacks

* Stacks are treated as individual assets for info/metadata, tag membership, and album membership.
* Live Photos _are not_ stacks.
* If all the assets in a stack are deleted or removed from the stack, the stack will be deleted.

### Stack Creation

* When creating a stack, if the new stack contains non-primary asset ids from
  other stacks, those assets will be removed from their previous stacks and
  added to the new stack. This _may_ leave old stacks with only a single asset.

* When creating a stack, if the new stack contains asset ids that are the
  primary asset of a different stack, all asset ids in the other stack(s) will
  be additionally added into the new stack (and removed from their previous one).

* In both of the above cases, if the operation results in the old existing stacks
  empty, they will be deleted

