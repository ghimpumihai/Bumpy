import { ExclusionReason, type SessionSummary } from "@/types/sessions";

type CaveatSource = Pick<SessionSummary, "exclusionReasons" | "sicknessExperimental">;

/**
 * Why a trip's sickness numbers are experimental. The read API also sets `sicknessExperimental` when the
 * mount is simply unknown (session.json never arrived), which must not read as "not rigid".
 */
export function sicknessCaveat(session: CaveatSource): string | null {
  if (!session.sicknessExperimental) return null;
  const reasons = session.exclusionReasons;
  if (reasons.includes(ExclusionReason.HANDHELD)) return "Experimental: hand-held";
  if (reasons.includes(ExclusionReason.NOT_RIGID)) return "Experimental: mount not rigid";
  if (reasons.includes(ExclusionReason.UNKNOWN_CONTEXT)) return "Experimental: mount unknown";
  return "Experimental";
}
