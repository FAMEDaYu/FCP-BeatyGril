# 2.4.0 region / pin branch review

2026-10-23. Independent read-only review of the existing AIR and local arm64
slice. No shared REA operation, target execution, product edit, Git operation,
or user image/landmark extraction was performed.

## The default-path correction

**The inspected main encoders and both direct fallback callers select mode 0
(pin), not region. Fragment buffer 8 is sampleFlipY, not faceThinMode.**

AIR file: `build/vface-analysis/new-face-thin.air.txt`, SHA-256
`1d5bd8d5a3917afbb3b4fe1c40b44480760614102685ac826e84ad2e30a450f9`.
Arm64 slice: `build/tracking-audit/MSE18V2-arm64`, SHA-256
`afc71d0d21fd3c1ca95ca745ddafcd729e36ad95f17d8638009f2e45d9b7e8df`.

AIR metadata lines 4126–4135 give the actual Metal binding indices:

| Fragment buffer | Name | AIR parameter |
| --- | --- | --- |
| 0 | facePoints | `%3` |
| 1 | faceCount | `%4` |
| 2 | faceThinStrength | `%5` |
| 4 | faceThinMode | `%6` |
| 7 | faceShapeParams | `%7` |
| 8 | sampleFlipY | `%8` |
| 9 | warpFlipY | `%9` |
| 10 | sourceSampleRect | `%10` |

This is not merely a name inference: lines 447–465 load `%6`, test it `>0`,
and choose region. Lines 569–583 load `%8` and perform the final sample Y flip.

The independent native instruction check used Xcode llvm-objdump on that exact
slice; addresses below are original virtual addresses. The ObjC stub
`0x100081d00` is `setFragmentBytes:length:atIndex:` in the saved REA pseudocode.

| Native path | Source of buffer 4 data | Binding instructions | Result |
| --- | --- | --- | --- |
| `FUN_100030084` | `0x1000300d0: str wzr,[sp,#0x70]` | `0x100030524 add x2,sp,#0x70`; `0x100030530 mov w4,#4`; call `0x100030534` | mode 0 |
| `FUN_100030840` | `0x100030888: str wzr,[sp,#0x70]` | `0x100030bf4 add x2,sp,#0x70`; `0x100030c00 mov w4,#4`; call `0x100030c04` | mode 0 |
| `FUN_10003127c`, called at `0x100027a34` | caller `0x1000279f8 str wzr,[sp,#0x18]` | callee `0x10003156c add x2,x29,#0x28`; `0x100031578 mov w4,#4`; call `0x10003157c` | mode 0 |
| `FUN_10003127c`, called at `0x10002be14` | `0x10002bd04 str wzr,[sp,#0xbc]`; `0x10002bdb4 ldr w9,[sp,#0xbc]`; `0x10002bde0 str w9,[sp,#0x18]` | same callee binding | mode 0 |
| inline fallback in `FUN_10002b8a4` | same zero at `0x10002bd04` | `0x10002bf74 add x2,sp,#0xbc`; `0x10002bf80 mov w4,#4`; call `0x10002bf84` | mode 0 |

The callee creates a 0x110-byte frame and sets fp=sp+0x100, so its fp+0x28
is the caller's sp+0x18. The whole decoded executable text contains exactly
the two direct `bl 0x10003127c` calls listed above. This bounds the conclusion:
the inspected default/fallback paths do not establish any fixed region=1 path;
this is not an exhaustive exclusion of arbitrary indirect calls or runtime
buffer replacement.

Saved provider corroboration in `renderpath-evidence.json`:

- `0x100030084`: `ev_f6e9622db324900aa5bc7d21598097df4abfb2f1270503751af959c61d7c8405`.
- `0x100030840`: `ev_30343763e68d261f018fb476b50a8695ca677d85cbcea9eda709c4e46c89ada6`.
- `0x10003127c`: `ev_537b8f52a769c64a08223b18f0fb2fd1a0b1daa0f44ffeb9b5c132513a9bcaf8`.
- inline fallback `0x10002b8a4`: `ev_4a2bf9e0530d651ae929ef861a2c52bfdf691445def0a16d8bbe07d723ce0c0e`.

## Exact shader branch contract

`faceThinFragmentShader` lines 388–587:

1. `warpFlipY` optionally flips the working UV before deformation (389–402).
2. Source texture width/height are read and clamped to >=1 (427–434).
3. If any shape parameter is active, iterate faces with **stride77** (454).
   With mode>0, run region with `clamp(abs(shoulian)*40,0,1)` (458–465), then
   run the other shape pins with thin forced to0 (470–474). With mode0, run
   `mssFaceShapePinCoordinate` with the original thin parameter (478).
4. If the shape structure is inactive but the separate faceThinStrength is
   active, mode>0 uses region directly with clamped overall strength (506);
   mode0 calls the old thin pin with `0.025*clamp(strength,0,1)` (510–512).
5. Clamp UV, undo warpFlipY, map sourceSampleRect, clamp again, apply sampleFlipY,
   then sample the source (521–583). These are separate coordinate operations.

The active-shape pin helper's thin branch at 3168–3268 uses its incoming thin
ratio directly in the sequential17 pin field. Its pixel-size vector is not
used in that branch. This does not alone prove the CPU supplies no size gain;
CPU parameter generation remains a separate evidence question.

Therefore region should not replace the default field based on buffer8=1.
The current frame's qualified points may be accepted as-is without implying
that its spatial warp must be changed to region.

## Region function, retained as an optional-path analysis

`mssFaceThinRegionCoordinate` is lines 706–2835 (another copy appears at
4369 onward inside the offset-map shader). Its inputs are working UV, readonly
point array, face offset, strength, and source texture size. There is **no time,
previous frame, previous point set, persistent buffer write, texture history,
atomic, or other temporal input**. All stores in this function initialize local
index arrays. It is a pure spatial function of the supplied points/parameters.

Use `S=(sourceTextureWidth,sourceTextureHeight)`; the point buffer stores UVs.
The function loads `P76` as center (747–750), obtains contour bounds from all
17 points59..75 (714–793), and computes `W/H` as contour spans multiplied by S
(757–772). It returns identity for W<=1 or H<=1 (773–776).

Query `p=uv*S` at810. Radius, distance, axis normalization, and most amplitude
caps are calculated in **pixel space**. The contour center and all point
positions must be multiplied componentwise by S before such operations.
Displacements are divided componentwise by S to return to UV. Substituting UV
Euclidean distance for pixel Euclidean distance changes the aspect behavior.

The main axis is normalized `P67*S - P76*S`, falling back to (0,1); its
perpendicular is `(axis.y,-axis.x)` (863–894). This is based on chin and center,
not a fixed vertical image direction, and follows head roll.

Strength `s=clamp(input,0,1)` is nonlinearly mapped:
`u=mix(s,s*s*(3-2*s),.28)`, `a=.105*u*(1.08-.08*u)` (795–805).
Aspect and asymmetric left/right center-to-contour spans modulate the field
(812–841). These are spatial shape adaptations, not temporal smoothing.

The output is a combination of:

- An analytic side contraction with head-local horizontal/vertical smooth
  envelopes and analytic face support (862–1117).
- A neighbor-aware17-contour weighted field (1133–1638), with protected center
  anchors, smooth radial/directional support, weight-sum normalization and a
  pixel amplitude cap.
- Another17-contour field with strength-dependent neighboring-point averaging
  (`mix(Pi,(Pprev+2*Pi+Pnext)/4,alpha)`,1683–1699); contour index distance from
  chin67 affects weights (1704 onward); contributions are accumulated before
  normalization rather than sequentially updating the query (1905–1939).
- Additional lower-face/chin components using65..69, including a three-point
  chin mean and roll-aware local envelopes (1954–2765).

Final group caps include `(0.04+.066*s)*W` and `(0.064+.058*s)*W`
(2785–2814). The final face envelope multiplies the total by
`.32+.68*analyticMask`, then returns `clamp(uv-totalUVDisplacement,0,1)`
(2815–2829). This is an inverse sampling field.

These features can reduce sensitivity to an isolated spatial point perturbation
if this mode is selected; that is an inference about the mathematics, not a
measured temporal improvement or evidence that the default path uses it.

## Protection formulas

Below `smooth(a,b,x)` means smoothstep with clamped input. All dimensions and
distances here are in pixels, and decimal constants are decoded AIR float
constants (small float rounding retained in the original text).

Let `C=P76*S`, `D=normalize(P67*S-C)`, `T=(D.y,-D.x)`.

Analytic face mask, lines2839–2916:

```
q = p-C-.12*H*D
x = dot(q,T)/max(.5*W,1)
y = dot(q,D)/max(.7*H,1)
r = sqrt(x*x+y*y)
mask = (1-smooth(.88,1.03,r)) * smooth(-.92,-.72,y)
       * (1-smooth(1.02,1.16,y))
```

Temple factor, lines3047–3149:

```
x = abs(dot(p-C,T))/max(.52*W,1)
y = dot(p-C,D)/max(.60*H,1)
k = smooth(-.28,-.02,y) * (1-smooth(.42,.72,y))
factor = clamp(1
  -.62*smooth(.50,.80,x)*(1-smooth(-.46,-.14,y))*(1-.86*k)
  -.20*smooth(.34,.70,x)*(1-smooth(-.72,-.34,y))*(1-.70*k), .30,1)
```

Anchor factor, lines2993–3043: indices47/48/49/52/76; radius
`R=max(12,.28*min(W,H))`; take the minimum
`smooth(.34*R,R,distance(p,Pi*S))`, then clamp to [.12,1].

Chin/mouth factor, lines2929–2977: indices47/48/49/52; radius
`R=max(10,.16*min(W,H))`; take the minimum
`smooth(.38*R,R,distance(p,Pi*S))`, then clamp to [.24,1].

The floors protect without hard disabling the whole field. Several region
subcomponents additionally interpolate these factors by their local support,
so merely multiplying an old17-pin warp by these factors is not equivalent.

## Smallest justified alignment path

For the inspected default: keep the pin family and validate the actual CPU
ratios, point layout/UV orientation, operation order and optional offset-map
processing. Do not insert region or stronger point smoothing as an asserted
fix for the user's clip. The large eye control and any offset-map spatial
filter need their own evidence; this review has not established their exact
runtime contribution.

Only if a separate reachable region-mode path is later established should its
field be reconstructed. A faithful implementation needs the pure coordinate
function, all four protections, pixel-space geometry, contour accumulation and
caps, followed by the remaining shape pins with thin=0. Evaluate that same
coordinate map for RGB and every mask. A generated float2 offset texture plus
one inverse sampler is a viable integration boundary; a reduced grid introduces
an approximation and needs measured UV error. Temporal state belongs upstream.

No region=1 runtime path or target output has been observed by this audit.
