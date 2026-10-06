# CLAYMORPHISM.md: beeef design spec (starter copy) for AI agents

Follow these tokens verbatim. Accessibility rules are NOT optional.
Reference prototype: `docs/design/battle.html` (round page: live, locked, closed).
Style source: the `design-it/claymorphism` skill (sickn33/agentic-awesome-skills), adapted to a light green palette.

== 1. Visual identity ==
Soft, inflated clay blocks that sit ON the page (drop shadow) and get volume from two inner shadows.
Unlike neumorphism, surfaces are a different color from the page.
Light mode:
  --bg:         #DDF2D4  /* mint page */
  --surface:    #F3FBEF  /* clay card */
  --surface-2:  #E8F7E1  /* selected / nested clay */
  --brand:      #7ED67A  /* clay green: primary button, selected chips, dial arc, meter */
  --brand-deep: #2E8B3C  /* leader line on the race chart */
  --edge:       #33893D  /* borders + focus ring (>= 3:1 on bg and surface) */
  --ink:        #2A7535  /* green words in headings */
  --on-brand:   #0F2412  /* text on --brand (9.2:1) */
  --sun:        #FFD84D  /* Winning / Won / Early bird pills, text --on-sun #2B2100 (11.5:1) */
  --up #17692E (6.4:1)   --down #B02A2A (6.2:1)
Dark mode: --bg #162619, --surface #1F3324, --surface-2 #26402C, --text #E8F6E2, --text-muted #B5CDB6,
  --brand #7ED67A, --up #8BE39A, --down #FF9E9E (all >= 6.8:1 on surface).
Why yellow for Winning: green already means "up". A green Winning pill on a side that is down would lie.
Radius: 32px blocks, 28px on phones, fully round pills and circles. No sharp corners anywhere.

== 2. Shadow recipes (the whole look) ==
Clay block:
  box-shadow: 14px 14px 28px rgba(46,104,52,.22),      /* outer: lifts off the page */
              inset -8px -8px 16px rgba(46,104,52,.14), /* inner dark, bottom-right */
              inset 8px 8px 16px rgba(255,255,255,.85); /* inner light, top-left */
Small clay (chips, steppers): same at half the offsets.
Green clay (primary button, selected chip): outer rgba(46,124,52,.35), inner dark rgba(30,110,40,.28),
  inner light rgba(255,255,255,.55).
Well (amount input, meter track, selected check): inset 5px 5px 12px rgba(46,104,52,.2),
  inset -5px -5px 12px rgba(255,255,255,.8).
Pressed: small outer shadow + stronger insets, and scale(.95).
Dark mode keeps the same structure with black outer/inner darks and 5-6% white highlights.

== 3. Motion ==
Bouncy spring: transition: transform .25s cubic-bezier(0.34, 1.56, 0.64, 1).
Hover: translateY(-3..-5px) scale(1.02..1.04). Press: scale(.94..0.95).
prefers-reduced-motion: no transforms, no transitions.

== 4. Typography ==
Display (logo, title, panel headings): Fredoka 700. Everything else: Nunito 600-900.
Never thin weights: they disappear next to the heavy clay.
Numbers use font-variant-numeric: tabular-nums.
  --text #15301B (12.0:1 on bg, 13.5:1 on surface), --text-muted #34503A (>= 7:1 on both).

== 4a. Round page layout ==
Desktop (> 920px): header row (logo, battle chips, ?), then the series tag and the question, then two columns.
  Left (1.55fr): the race tray, a tinted inset well holding the countdown dial + "NVDA is winning" + pot,
  the face-off (side A, yellow VS bubble, side B) and the race chart.
  Right (1fr, sticky): the bet panel (or Bets locked / closed results), then Latest bets.
Phone: one column in this order: countdown + status, face-off, bet panel, latest bets, chart.
Never stack everything in one centered column on desktop.

== 4b. Components ==
Side cards (radio group): clay block, tap to pick. Selected = --edge 3px border + --surface-2 + green check
  bubble with a tick (color + shape + ARIA, never shadow alone).
Primary button: green clay pill, label --on-brand, "Bet $25 on NVDA · 0.62x".
Secondary button: surface clay pill with a 3px --edge border ("Share").
Amount: well with a round "-" clay button and a green "+" clay button; $5 / $10 / $25 / $50 chips.
Multiplier meter: well track, green clay fill that drains.
Dial: surface clay ring, well groove, green arc; the value is printed in the knob.
Race chart: clay card, leader line --brand-deep, other line muted, dashed zero line.
Lists (bets in a closed round): flat rows with dashed dividers inside one clay card, no clay per row.

== 4b. Copy rules (beeef) ==
  - The title is the question: "NVDA vs AMD: who will be up more?"
  - Every asset shows its logo in a round "coin" (white chip, brand mark or coin art).
  - Time is ONE countdown ("18:29 to go", "0:41 to the bell"). No clock times, no time zones, no round format.
  - Rounds are always live. Never show 0.00% as a placeholder and never mention a halfway cutoff.
  - Round page states: Live (bet panel), Locked (final 60s, "Bets locked" + Share), Closed (result, every bet with
    its multiplier, then "Go to next round" for a recurring series or "Rematch" for a one-off).
  - Rematch never starts on its own. Tapping Rematch on a closed one-off opens "Start the rematch" (pick a side,
    $5/$10/$25/$50, "Start rematch · $25 on NVDA", "Plus $1 to seed AMD, so either side can pay out."). After it
    starts: "Rematch is live" with Share on X (prefilled "Rematch: NVDA vs AMD. I'm on NVDA. Who will be up more?")
    and Go to rematch. If someone already started it, Rematch goes straight to that round.
  - A small tag under the title: "Recurring · round 14 of 50", "Recurring · round 3" (no end), or "One-off".
  - The multiplier is the one number about timing: "Bet now: 0.62x. In 1 minute: 0.55x.", a draining meter, and the
    button "Bet $25 on NVDA · 0.62x". "You win" applies the multiplier and carries an "est." tag.
  - Use exactly these two lines for the rules: "Bet anytime. Earlier bets count more." and
    "Bets lock 60s before the bell."
  - Race chart: % move since the start for both sides on one axis, zero line dashed, leader's line orange, the
    other muted, end labels "NVDA +1.87%". It is read-only: nothing on it looks draggable.
  - Money is dollars ("$25", "$1,285 pot"). Never show the stablecoin's name (USDG) in the UI.
  - Never name infrastructure (Chainlink, Doppler, Robinhood Chain, oracle, migrate).
  - The score is the % move since the race started, never the price. DOGE at $0.24 vs PEPE at $0.00001 says
    nothing; "+3.95% vs -1.10%" says who is winning. Never show asset prices on the battle screen.
  - The two sides sit side by side. Each shows only logo, ticker and its move: "▲ 3.93%" in green or
    "▼ 1.11%" in red. The side that moved more gets an orange "Winning" tag, and one line says "PEPE is winning".
    Down 5% beats down 6%. No tracks, sliders or anything that looks draggable.
  - No payout multipliers or "% you'd win" on the side cards.
  - Labels are 1-2 words ("to go", "to the bell", "You win"). Rules live behind the "?" button, 3 short lines max.
  - Buttons say the action with the numbers in it: "Bet $25 on AMD", "Claim $43.28".

== 5. Accessibility requirements (mandatory) ==
  - Body text >= 7:1, never below 4.5:1 (WCAG AA floor)
  - Non-text UI (borders, rings, arcs that carry meaning) >= 3:1: use --edge, not --brand
  - Every interactive element needs a non-shadow cue: accent color, border, or label
  - Focus: visible 3px --edge ring via :focus-visible, offset 3px
  - Hit target >= 44x44px (WCAG 2.2)
  - Pressed state squishes (scale .95 + stronger insets) AND sets the ARIA state
  - Respect prefers-reduced-motion (no arc sweeps, no countdown pulse)

== 6. Common mistakes AI agents make ==
  - Surfaces the same color as the page (that is neumorphism, not clay).
  - A single drop shadow with no inner shadows: flat cards, not clay.
  - Green text on the mint page for body copy (use --text / --text-muted), or --brand as a border (fails 3:1).
  - Green "Winning" pills: green means up. Winning is --sun.
  - Linear or instant motion: clay needs the bouncy spring.
  - Thin fonts.
