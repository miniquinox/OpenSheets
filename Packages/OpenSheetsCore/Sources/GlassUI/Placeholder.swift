/// Design tokens — the one place to touch the look, per the house pattern in
/// `SignalToNoise/App/Design/DesignSystem.swift`.
///
/// **Empty on purpose.** A5 owns the palette, the radii, the motion curves, and the
/// typography roles, and designing them is that agent's whole job. This declaration exists
/// only so that anything referring to `DS` in Wave 0 compiles; picking colours here would
/// mean A5 starts by deleting someone else's guesses.
public enum DS {}
