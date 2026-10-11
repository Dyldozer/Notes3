#Requires AutoHotkey v2.0
; Defaults.ahk - the built-in config (PLAN section 5.5). Source of truth for "Restore defaults".
; Business wording (reasons, contact, outcomes, fragments) is deliberately PLACEHOLDER text;
; the real wording is set in the milestone named in each placeholder.

class Defaults {
    ; A fresh Map/Array tree on every call (callers may mutate it).
    static Config() {
        cfg := Map()
        cfg["schemaVersion"] := 1
        cfg["revision"] := 0
        cfg["updatedAt"] := "2026-10-10T00:00:00"      ; fixed so the exported file is stable
        cfg["updatedBy"] := "built-in"
        cfg["noteTemplate"] := Map(
            "lines", ["Tech name: {tech.firstName}", "Tech ID: {tech.id}", "Job Number: {job.number}", "Notes: {notes}"],
            "unavailableText", "[not available]",
            "fragmentJoiner", " ",
            "categoryJoiner", "`n",
            "sentenceCase", true,
            "endPunctuation", ".")
        cfg["contextFields"] := [
            Map("id", "techName", "label", "Technician"),
            Map("id", "techId", "label", "Tech ID"),
            Map("id", "address", "label", "Address"),
            Map("id", "jobNumber", "label", "Job number"),
            Map("id", "workOrder", "label", "Work order")]
        cfg["categories"] := [Defaults.NotDone(), Defaults.Equipment(), Defaults.Billing(),
            Defaults.StaticCat(), Defaults.CloseJob()]
        cfg["themes"] := Map(
            "default", "spectrum-light",
            "presets", [
                Map("id", "spectrum-light", "label", "Spectrum - light", "sheet", "spectrum", "mode", "light", "accent", "#0099D8"),
                Map("id", "spectrum-dark", "label", "Spectrum - dark", "sheet", "spectrum", "mode", "dark", "accent", "#0099D8"),
                Map("id", "win365", "label", "Microsoft 365 (plain)", "sheet", "win365", "mode", "light", "accent", "#0F6CBD")])
        cfg["ping"] := Map("timeoutMs", 1000, "attempts", 4, "intervalMs", 1000, "untilSuccessMaxMin", 10)
        cfg["callTracking"] := Map("newCallDebounceMs", 3000)
        cfg["history"] := Map("retentionDays", 14)
        return cfg
    }

    ; --- helpers -------------------------------------------------------------
    static Opt(id, label, fragment) => Map("id", id, "label", label, "fragment", fragment)

    static Cat(id, label, icon, kind) => Map("id", id, "label", label, "icon", icon,
        "enabled", true, "system", true, "kind", kind, "notePrefix", "")

    ; n placeholder options "<label> <i> (placeholder)", ids <idPrefix><i>, fragment "<label> <i> placeholder note."
    ; (+ " " extra when given, e.g. a {fieldId} placeholder).
    static Placeholders(idPrefix, label, n, extra := "") {
        out := []
        loop n
            out.Push(Defaults.Opt(idPrefix A_Index, label " " A_Index " (placeholder)",
                label " " A_Index " placeholder note." (extra != "" ? " " extra : "")))
        return out
    }

    ; --- categories ----------------------------------------------------------
    ; Not Done (PLAN 5.3). Everything except the order types, Yes/No, the supervisor question and the
    ; Trouble Call stop text is PLACEHOLDER wording (see docs\handoff\M5.md, "Filling in the placeholder text").
    static NotDone() {
        c := Defaults.Cat("notDone", "Not Done", "E711", "steps")
        stopNo := Defaults.Opt("no", "No", "")
        stopNo["stop"] := Map("message", "The tech must contact their supervisor before calling back.",
            "fragment", "Tech has not contacted supervisor; advised tech to contact supervisor before calling back.",
            "keepSteps", ["reason", "orderType"])
        c["steps"] := [
            Map("id", "reason", "label", "Reason (placeholder)", "type", "choice", "required", true,
                "options", Defaults.Placeholders("r", "Reason", 4)),
            Map("id", "orderType", "label", "Order type", "type", "choice", "required", true, "options", [
                Defaults.Opt("pwo", "PWO", "Order type PWO placeholder note."),
                Defaults.Opt("tc", "TC", "Order type TC placeholder note."),
                Defaults.Opt("sro", "SRO", "Order type SRO placeholder note.")]),
            Map("id", "supervisorPwo", "label", "Supervisor contact (PWO)", "type", "group",
                "when", Map("step", "orderType", "in", ["pwo"]),
                "fields", [
                    Map("id", "supervisorName", "label", "Supervisor name", "required", true),
                    Map("id", "rescheduleReason", "label", "Reason for reschedule", "required", true, "multiline", true)],
                "fragment", "Supervisor {supervisorName} placeholder note. Reschedule reason {rescheduleReason} placeholder note."),
            Map("id", "supervisorTc", "label", "Has the tech spoken with their supervisor?", "type", "yesno",
                "required", true, "when", Map("step", "orderType", "in", ["tc"]),
                "options", [Defaults.Opt("yes", "Yes", "Tech spoke with supervisor {supervisorNameTc} placeholder note."), stopNo],
                "fields", [Map("id", "supervisorNameTc", "label", "Supervisor name", "required", false,
                    "requiredWhen", Map("step", "supervisorTc", "in", ["yes"]))]),
            Map("id", "contact", "label", "Contact (placeholder)", "type", "choice", "required", true,
                "options", Defaults.Placeholders("c", "Contact", 4, "{contactDetails}"),
                "fields", [Map("id", "contactDetails", "label", "Contact details (placeholder)", "required", false)]),
            Map("id", "outcome", "label", "Outcome (placeholder)", "type", "choice", "required", true,
                "options", Defaults.Placeholders("o", "Outcome", 4))]
        c["flags"] := [Map("id", "reason4Sro",
            "when", Map("all", [Map("step", "reason", "in", ["r4"]), Map("step", "orderType", "in", ["sro"])]),
            "message", "Placeholder flag: Reason 4 with SRO may need review.")]
        return c
    }

    ; n placeholder items "Item <i> (placeholder)", ids item<i>.
    static PlaceholderItems(n) {
        out := []
        loop n
            out.Push(Map("id", "item" A_Index, "label", "Item " A_Index " (placeholder)"))
        return out
    }

    ; Equipment (PLAN 3.5): actions Added / Removed / Swapped are real; the item list and fragment wording are
    ; PLACEHOLDER text (see docs\handoff\M6.md, "Filling in the placeholder text").
    static Equipment() {
        c := Defaults.Cat("equipment", "Equipment", "E772", "items")
        frag := "{action} {qty} {item}. {details}"
        c["entry"] := Map(
            "actions", [
                Defaults.Opt("added", "Added", frag),
                Defaults.Opt("removed", "Removed", frag),
                Defaults.Opt("swapped", "Swapped", frag)],
            "items", Defaults.PlaceholderItems(5),
            "outcomes", [],
            "outcomeRequired", false,
            "qty", true, "details", true)
        return c
    }

    ; Billing (PLAN 3.4): actions Added / Removed / Changed and the three outcomes are real; the item list and the
    ; action wording are PLACEHOLDER text. Only the Completed outcome says "completed" as a claim.
    static Billing() {
        c := Defaults.Cat("billing", "Billing", "E8C7", "items")
        frag := "{action} {qty} {item} {details}"
        c["entry"] := Map(
            "actions", [
                Defaults.Opt("added", "Added", frag),
                Defaults.Opt("removed", "Removed", frag),
                Defaults.Opt("changed", "Changed", frag)],
            "items", Defaults.PlaceholderItems(5),
            "outcomes", [
                Defaults.Opt("completed", "Completed", "- completed."),
                Defaults.Opt("requested", "Requested " Chr(0x2014) " not yet completed", "- requested, not yet completed."),
                Defaults.Opt("unable", "Unable to complete", "- unable to complete.")],
            "outcomeRequired", true,
            "qty", false, "details", true)
        return c
    }

    ; Static (PLAN section 7): the IPv4 maths and the gateway rule are code-only. The config holds only wording:
    ; the ping target labels and the ping outcome lines. The outcome labels "Reply received" / "No reply" are real (PLAN 3.7); every sentence is PLACEHOLDER text
    ; (see docs\handoff\M7.md, "Filling in the placeholder text").
    static StaticCat() {
        c := Defaults.Cat("static", "Static", "E774", "static")
        c["static"] := Map(
            "pingTargets", [
                Map("id", "gateway", "label", "Gateway"),
                Map("id", "ip", "label", "IP")],
            "pingOutcomes", [
                Defaults.Opt("reply", "Reply received", "Ping to {pingTarget} {pingAddress}: reply received (placeholder wording)."),
                Defaults.Opt("noReply", "No reply", "Ping to {pingTarget} {pingAddress}: no reply (placeholder wording).")])
        return c
    }

    static CloseJob() {
        c := Defaults.Cat("closeJob", "Close Job", "E73E", "steps")
        c["steps"] := [
            Map("id", "closeChoice", "label", "Close choice (placeholder)", "type", "choice", "required", true,
                "options", Defaults.Placeholders("k", "Close option", 3)),
            Map("id", "closeFollowUp", "label", "Close yes/no question (placeholder)", "type", "yesno", "required", false,
                "options", [Defaults.Opt("yes", "Yes", "Close question yes placeholder note."),
                    Defaults.Opt("no", "No", "")]),
            Map("id", "closeText", "label", "Close text (placeholder)", "type", "text", "required", false,
                "fields", [Map("id", "closeNote", "label", "Close note (placeholder)", "required", false)],
                "fragment", "Close note {closeNote} placeholder note.")]
        return c
    }
}
