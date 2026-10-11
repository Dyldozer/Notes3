#Requires AutoHotkey v2.0

class TestCallContext {
    static Name := "CallContext"

    static Run() {
        for name in ["Defaults", "SetRules", "SetManual", "Clone", "Merge"]
            T.Case(name, ObjBindMethod(TestCallContext, name))
    }

    static Defaults() {
        c := CallContext()
        T.Eq(c.Ids().Length, 5, "five required fields")
        for id in ["techName", "techId", "address", "jobNumber", "workOrder"] {
            T.True(c.Has(id), "has " id)
            T.Eq(c.Value(id), "", id " value empty")
            T.Eq(c.Status(id), "empty", id " status empty")
        }
        T.Eq(c.Value("nope"), "", "unknown id value is empty text")
        T.Eq(c.Get("nope"), "", "unknown id Get is empty text")
    }

    static SetRules() {
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock", "mock")
        f := c.Get("techName")
        T.Eq(f.Value, "Jordan Smith", "mock value kept")
        T.Eq(f.Status, "mock", "mock status kept")
        T.Eq(f.Source, "mock", "source kept")
        T.True(f.ReadAt != "", "ReadAt set")
        c.Set("techId", "T1", "live", "appbar:uia")
        T.Eq(c.Status("techId"), "live", "live accepted")
        c.Set("address", "x", "unavailable")
        T.Eq(c.Value("address"), "", "unavailable never carries a value")
        T.Eq(c.Status("address"), "unavailable", "unavailable status kept")
        c.Set("jobNumber", "9", "empty")
        T.Eq(c.Value("jobNumber"), "", "empty never carries a value")
        c.Set("workOrder", "", "mock")
        T.Eq(c.Status("workOrder"), "empty", "blank value with a mock status becomes empty")
        c.Set("workOrder", "55-1", "bogus")
        T.Eq(c.Status("workOrder"), "empty", "unknown status becomes empty")
        T.Eq(c.Value("workOrder"), "", "unknown status carries no value")
        c.Set("techName", "Old Name", "stale")
        T.Eq(c.Value("techName"), "Old Name", "stale keeps its last value")
        for id in c.Ids() {
            f := c.Get(id)
            T.True(f.Value != "" || f.Status = "empty" || f.Status = "unavailable", "rule holds for " id)
        }
        T.True(CallContext.IsStatus("history"), "history is a status")
        T.False(CallContext.IsStatus("Mockish"), "unknown is not a status")
    }

    static SetManual() {
        for st in ["unavailable", "empty", "stale"] {
            c := CallContext()
            c.Set("techName", st = "stale" ? "Old" : "", st)
            T.True(c.SetManual("techName", "  Typed Name "), "manual allowed over " st)
            T.Eq(c.Status("techName"), "manual", "status manual after " st)
            T.Eq(c.Value("techName"), "Typed Name", "value trimmed after " st)
            T.Eq(c.Get("techName").Source, "agent", "source agent after " st)
            T.False(c.Get("techName").Editable, "manual is not editable again")
        }
        for st in ["live", "mock", "manual", "history"] {
            c := CallContext()
            c.Set("techName", "Keep Me", st)
            T.False(c.SetManual("techName", "Other"), "manual refused over " st)
            T.Eq(c.Value("techName"), "Keep Me", "value untouched over " st)
            T.Eq(c.Status("techName"), st, "status untouched over " st)
        }
        c := CallContext()
        T.False(c.SetManual("techName", "   "), "blank manual refused")
        T.Eq(c.Status("techName"), "empty", "blank manual changes nothing")
        T.False(c.SetManual("nonexistent", "x"), "unknown field refused")
    }

    static Clone() {
        c := CallContext()
        c.Set("jobNumber", "100", "mock")
        d := c.Clone()
        d.Set("jobNumber", "200", "live")
        T.Eq(c.Value("jobNumber"), "100", "original unchanged by clone edit")
        T.Eq(d.Value("jobNumber"), "200", "clone edited")
        c.Set("techId", "T9", "mock")
        T.Eq(d.Value("techId"), "", "clone not affected by later original edit")
        T.Eq(d.Ids().Length, c.Ids().Length, "clone has the same fields")
    }

    static Merge() {
        cur := CallContext()
        cur.Set("address", "", "unavailable")
        cur.SetManual("address", "Typed St")
        cur.Set("techName", "A", "mock")
        cur.SetManual("techId", "T7")                    ; empty -> manual
        up := CallContext()
        up.Set("address", "", "unavailable")             ; still nothing from the provider
        up.Set("techName", "B", "mock")
        up.Set("techId", "T-live", "live")               ; provider now has a real value
        cur.MergeProvider(up)
        T.Eq(cur.Value("address"), "Typed St", "manual kept while provider has nothing")
        T.Eq(cur.Status("address"), "manual", "still manual")
        T.Eq(cur.Value("techName"), "B", "normal field follows the provider")
        T.Eq(cur.Status("techId"), "live", "a live value replaces a manual one")
        T.Eq(cur.Value("techId"), "T-live", "live value shown")
    }
}
