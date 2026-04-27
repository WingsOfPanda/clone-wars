# lib/colors.sh — per-commander signature colors for pane border labels.
#
# Every color is drawn from a curated Morandi (莫兰迪) palette — the muted,
# dust-and-mist style of Italian painter Giorgio Morandi. Each color sits in
# the 10-40% saturation band so the whole crew reads as a harmonious painting.
#
# Each commander has a TWO-color palette:
#   primary   — legion's identifying muted color (helmet base / torso)
#   secondary — a Morandi-friendly companion (rank stripes, kama, accents)
#               chosen for harmony, not contrast: cool/warm complements,
#               earth-tone analogues, mirror-complement mauves, etc.
#
# The label "<commander>-<model>-<topic>" can render two ways:
#   plain   (cw_color_for)     — single color, the legion primary
#   striped (cw_label_fmt)     — primary-secondary-primary armor-stripe alternation
#
# Reference Morandi palette mapped to tmux 256-color:
#   curated hex source — https://gist.github.com/ChuanyuXue/3a377f7c1629b0ce68bc6b393340d0fb
#   design notes      — Morandi colors pair best with soft neutrals + small accents.
#
# Canon armor sources:
#   https://starwars.fandom.com/wiki/212th_Attack_Battalion
#   https://starwars.fandom.com/wiki/Coruscant_Guard
#   https://starwars.fandom.com/wiki/Clone_Force_99
#   https://crls.501st.com/ctd/clone-trooper

# cw_palette_for <commander> — print "<primary> <secondary>" space-separated.
cw_palette_for() {
  local commander="${1,,}"
  case "$commander" in
    # 501st Legion — dusty blue/teal/violet primary + warm-cream/rose accents
    rex)        printf 'colour110 colour187\n' ;;  # dusty blue + warm cream (cool/warm)
    echo)       printf 'colour109 colour187\n' ;;  # dusty teal + cream
    fives)      printf 'colour67 colour187\n'  ;;  # mid slate + cream (swapped from 103 in v0.0.6: was adjacent to wolffe colour104)
    jesse)      printf 'colour60 colour250\n'  ;;  # slate-purple + soft white
    kix)        printf 'colour131 colour110\n' ;;  # dusty rose + dusty blue (medic reverse-armor)
    tup)        printf 'colour146 colour250\n' ;;  # dust-violet + soft white
    dogma)      printf 'colour103 colour187\n' ;;  # steel-blue + cream (swapped from 67 in v0.0.6: traded with fives for visual deduplication)
    hardcase)   printf 'colour152 colour187\n' ;;  # soft cyan + cream
    vill)       printf 'colour66 colour187\n'  ;;  # deep slate + cream
    deviss)     printf 'colour97 colour187\n'  ;;  # dusty plum + cream
    # 212th Attack Battalion — terracotta primary + cream/sage accents
    cody)       printf 'colour137 colour187\n' ;;  # terracotta + cream (Marshal)
    keeli)      printf 'colour173 colour144\n' ;;  # terracotta-orange + olive (Ryloth)
    havoc)      printf 'colour180 colour247\n' ;;  # peach + silver
    # 104th Wolfpack — blue-grey primary (canonical grey with violet undertone) + dusty rose accent
    wolffe)     printf 'colour104 colour174\n' ;;  # dusty periwinkle (Wolfpack blue-grey/violet) + rose
    blackout)   printf 'colour102 colour247\n' ;;  # neutral grey + silver
    # 327th Star Corps — cream primary + soft white accent
    bly)        printf 'colour187 colour250\n' ;;
    doom)       printf 'colour144 colour250\n' ;;  # olive-sage + white
    # Coruscant Guard — Morandi rose/pink primary + soft charcoal/white
    fox)        printf 'colour138 colour241\n' ;;  # warm rose + charcoal (black visor)
    thorn)      printf 'colour182 colour250\n' ;;  # dusty pink + white
    thire)      printf 'colour174 colour250\n' ;;  # soft rose + white
    stone)      printf 'colour96 colour250\n'  ;;  # dusty plum + white
    # 41st Elite Corps — sage primary + olive (earth tones)
    gree)       printf 'colour108 colour144\n' ;;  # sage + olive
    faie)       printf 'colour100 colour137\n' ;;  # olive-yellow + mushroom
    # 91st Reconnaissance Corps — beige + white
    ponds)      printf 'colour181 colour250\n' ;;  # warm beige + white
    neyo)       printf 'colour223 colour174\n' ;;  # peach-cream + rose
    # Galactic Marines
    bacara)     printf 'colour132 colour137\n' ;;  # mauve + mushroom (earth tones)
    # Clone Force 99 (Bad Batch) — earth/wine primary + soft charcoal
    hunter)     printf 'colour95 colour241\n'  ;;  # dusty wine + charcoal (bandana)
    wrecker)    printf 'colour101 colour241\n' ;;  # olive-brown + charcoal (scarred)
    tech)       printf 'colour139 colour241\n' ;;  # dusty plum + charcoal (lightning)
    crosshair)  printf 'colour250 colour241\n' ;;  # pale grey + charcoal (sniper)
    # Misc / lesser-known
    trauma)     printf 'colour218 colour250\n' ;;  # pink + white (medic)
    colt)       printf 'colour245 colour187\n' ;;  # mid grey + cream (ARC trainer)
    bow)        printf 'colour243 colour250\n' ;;  # cool grey + white
    *)          printf 'white default\n'       ;;
  esac
}

# cw_color_for <commander> — print just the PRIMARY color. Used by both the
# active-border swap hook and the simple single-color label format.
cw_color_for() {
  cw_palette_for "$1" | awk '{print $1}'
}

# cw_rank_for <commander> — canonical rank from Star Wars: The Clone Wars.
# Used as a prefix in the rendered label ("captain-rex", "commander-cody").
cw_rank_for() {
  local commander="${1,,}"
  case "$commander" in
    # Captains
    rex|keeli|trauma|colt)
      printf 'captain\n' ;;
    # Marshal Commanders / Commanders (the bulk of the named clone leaders)
    cody|wolffe|bly|fox|gree|ponds|bacara|neyo|doom|faie|thorn|thire|stone)
      printf 'commander\n' ;;
    # Sergeants (Bad Batch leader Hunter; 501st sergeant Jesse)
    hunter|jesse)
      printf 'sergeant\n' ;;
    # ARC troopers (specialist combat clones)
    fives|echo|havoc)
      printf 'arc' ;;
    # Bad Batch specialists
    wrecker|tech|crosshair)
      printf 'specialist\n' ;;
    # Standard troopers (rank-and-file 501st and unknowns)
    *)
      printf 'trooper\n' ;;
  esac
}

# cw_label_for <commander> <model> <topic> — render the canonical plain-text
# label: "<rank>-<commander>:<model>:<topic>". Stash in @cw_label.
cw_label_for() {
  printf '%s-%s:%s:%s\n' "$(cw_rank_for "$1")" "$1" "$2" "$3"
}

# cw_label_fmt <commander> <model> <topic> — print a tmux pane-border-format
# fragment with descending visual emphasis:
#   <rank>-<commander> → primary  (legion identity, most prominent)
#   <model>            → secondary (Morandi accent, mid-prominence)
#   <topic>            → default   (plain text, low-prominence "doing what")
# Colons (:) separate sections; hyphens (-) appear inside rank-commander and
# inside any multi-word topic. Stash in @cw_label_fmt per-pane to opt into
# the striped rendering.
cw_label_fmt() {
  local commander="$1" model="$2" topic="$3"
  local primary secondary rank
  read primary secondary < <(cw_palette_for "$commander")
  rank=$(cw_rank_for "$commander")
  printf '#[fg=%s,bold]%s-%s#[default]:#[fg=%s,bold]%s#[default]:%s' \
    "$primary" "$rank" "$commander" "$secondary" "$model" "$topic"
}
