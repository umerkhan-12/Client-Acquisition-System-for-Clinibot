# THE LAST FRAME — Resort Sequence Image Prompts

Concept art for the RS 01–08 setups on the moodboard. Original fictional
character — **not a likeness of any real person**. Label anything generated
from these as AI concept art in a pitch; it stands in for the shoot, it does
not represent it.

---

## The character block

Paste this verbatim at the head of every prompt. Consistency across a set
comes from repeating the same descriptors word for word — change one and the
face drifts.

> A fictional woman in her early thirties, South Asian, oval face with high
> cheekbones and a defined jawline, dark brown almond eyes, straight dark
> brown hair falling just past the shoulders with a natural side part, warm
> medium-brown skin, calm composed expression, minimal natural makeup

**Consistency method, in order of what actually works:**

1. Generate the close portrait (RS 07) first. Keep the best face.
2. Reuse it as a character reference — Midjourney `--cref <url> --cw 100`,
   Flux/SDXL an IP-Adapter or face reference at 0.6–0.8 weight.
3. Lock the seed and vary only the shot description.
4. Where the tool supports it, train a small LoRA on 8–12 accepted outputs.
   Overkill for a pitch board, correct if this becomes the game's character.

---

## Shared style suffix

Append to every prompt:

> cinematic film still, premium AAA game promotional key art, shot on ARRI
> Alexa, anamorphic, shallow depth of field, natural skin texture, film grain,
> luxury fashion editorial, warm golden hour grade with teal shadows,
> photorealistic, highly detailed, 8k

## Shared negative prompt

> cartoon, anime, illustration, 3d render, cgi, plastic skin, airbrushed,
> distorted hands, extra fingers, malformed limbs, watermark, text, logo,
> lowres, blurry, oversaturated, harsh flash, duplicate face

**Midjourney parameters:** `--ar 3:4 --style raw --stylize 250 --v 7`
(swap `--ar` per shot — noted on each below.)

---

## RS 01 — Poolside standing · full body

`--ar 3:4`

> [CHARACTER BLOCK], standing at the edge of a luxury infinity pool in
> elegant one-piece-cut swimwear in sand and ivory tones, full body wide
> composition, confident relaxed stance with weight on one hip, arms loose at
> her sides, city skyline hazy in the far background, infinity edge cutting
> the frame at the lower third, 35mm lens at f/4, bright midday sun with soft
> white bounce filling the shadows, [STYLE SUFFIX]

## RS 02 — Walking beside the pool · movement

`--ar 4:3`

> [CHARACTER BLOCK], walking along a poolside walkway in stylish swimwear
> with a long sheer ivory cover-up catching the breeze behind her, dark
> oversized sunglasses, mid-stride natural walking motion, tracking shot from
> her side, luxury resort architecture running past in the background,
> travelling camera, 50mm lens at f/2.8, hard midday sun with strong shadow
> under the walkway, [STYLE SUFFIX]

## RS 03 — Pool-edge portrait

`--ar 4:3`

> [CHARACTER BLOCK], seated at the edge of a pool with her legs in the water,
> elegant upright posture, one hand resting on the stone edge, looking
> directly into the lens with a composed unreadable expression, three-quarter
> body framing, 85mm lens at f/2, warm low afternoon sun from camera left,
> soft turquoise bounce from the water filling under the chin, [STYLE SUFFIX]

## RS 04 — Resort lounge · editorial

`--ar 4:3`

> [CHARACTER BLOCK], reclining on a woven lounge chair beneath a shaded
> pergola in swimwear and an open linen robe, relaxed but composed, one arm
> along the chair back, tropical planting and travertine architecture filling
> half the frame, high fashion editorial composition with strong horizontal
> shade lines across the scene, 40mm lens at f/2.8, open shade with warm gold
> bounce from sunlit stone, [STYLE SUFFIX]

## RS 05 — Over the shoulder, toward the resort · suspense

`--ar 4:3`

> [CHARACTER BLOCK], seen from behind and slightly to one side, wearing
> swimwear with a cover-up over her shoulders, turning her head to look back
> toward the resort buildings, long lens compression flattening the
> background, out-of-focus tropical foliage framing the left and bottom edges
> as if the camera is hidden behind it, sense of being observed from a
> distance, 135mm lens at f/2, hazy afternoon sun, [STYLE SUFFIX]

## RS 06 — Character hero shot

`--ar 3:4`

> [CHARACTER BLOCK], full body hero composition, standing centred and facing
> camera in elegant swimwear with a sheer cover-up, strong confident stance,
> shoulders square and chin level, symmetrical luxury resort architecture and
> the pool staged directly behind her, video game promotional key art
> framing, 28mm lens at f/5.6, bright even daylight with a gold rim from
> behind, [STYLE SUFFIX]

## RS 07 — Close portrait

`--ar 4:3`

> [CHARACTER BLOCK], close portrait framed at the face and shoulders, lifting
> dark sunglasses away from her eyes with one hand, hair moving in the
> breeze, sophisticated calm expression, poolside bokeh dissolved behind her,
> 105mm lens at f/2, backlit by low sun flaring through her hair with soft
> bounce on the face, [STYLE SUFFIX]

> Generate this one first — it becomes the face reference for the other seven.

## RS 08 — Walking away, into the resort · environment

`--ar 21:9`

> [CHARACTER BLOCK], small in a wide cinematic frame, seen from behind
> walking away from camera toward an infinity pool and resort buildings,
> swimwear with a long cover-up trailing, environment dominant and figure
> occupying a small portion of the composition, her silhouette dark against
> bright reflective water, 24mm lens at f/8, late afternoon sun low on the
> horizon, [STYLE SUFFIX]

---

## Working notes

- **Order:** RS 07 → RS 03 → RS 01 → the rest. Faces first, then bodies in
  space; correcting a face late means regenerating everything.
- **Batch size 4 per prompt.** Accept roughly one in four. Budget ~60 renders
  for eight usable frames.
- **The grade is the through-line.** If a frame comes back cool or neutral,
  reject it rather than colour-correcting — the resort sequence has to sit
  beside gold and emerald elsewhere in the board.
- **RS 05 is the one that carries the story.** If it doesn't feel like it was
  shot by someone hiding, the whole sequence reads as a swimwear shoot with
  a thriller pasted on top. Push the foreground foliage occlusion.
- These are pitch-stage concept frames. Don't put them in a deck beside a
  named performer's headshot without saying which is which.
