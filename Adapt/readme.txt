Adapt

This addon animates the unit frames of (nearly) any UI.

When the UI goes to draw a static portrait, this addon instead draws an animated model to the dimensions of the intended portrait. 

Adapt is meant to be configuration-free (especially if you use the default unit frames), but there are some options you can change in its Interface Options Panel.

=== FAQ

Q: Will it work with my custom unit frames?
A: If your existing unit frames are static portraits and not models already, yes it should. The universal approach this addon takes will attempt to convert any 2d portrait texture into a 3d model (if it's bigger than 30 pixels). However, if Adapt already came with the unit frame addon or UI compilation you use, you may need to get an updated version of that addon/compilation if it made any tweaks to portraits/Adapt.

Q: It's not working or there's a bug.
A: I'd love to hear about it in the comments. Please mention what Unit Frame addon or UI compilation you use.

Q: I use circular unit frames (like default), but when I look closely the model cut off as a square! Can the model be fit into a true circle?
A: Sadly, it can't. Addons have no genuine way to mask models. For circular unit frames the model is shrunk to fit within the circle.

Q: I want to disable my default focus frame from animating, but I don't see it in the options list.
A: The list in options is only of portraits it's encountered in that session (and those already disabled). Adapt has no idea what frames it will be asked to draw until it encounters them. So in this case you can /focus yourself and when you go back into options the focus frame should be listed so you can disable it.
