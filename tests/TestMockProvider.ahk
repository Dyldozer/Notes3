#Requires AutoHotkey v2.0

class TestMockProvider {
    static Name := "MockProvider"
    static Root := ""

    static Run() {
        TestMockProvider.Root := A_Temp "\NFSNotesTest_Mock_" A_TickCount
        for name in ["Basics", "NewCall", "Duplicate", "Burst", "States", "Health", "Subscribers", "Redaction", "BaseClass"]
            T.Case(name, ObjBindMethod(TestMockProvider, name))
        try DirDelete(TestMockProvider.Root, true)
    }

    static Boom(*) {
        throw Error("boom")
    }

    static Basics() {
        p := MockProvider()
        T.Eq(p.Kind, "mock", "kind is mock")
        T.True(MockProvider.JOBS.Length >= 5, "at least five fake technicians")
        c := p.GetContext()
        T.Eq(c.Value("techName"), "Jordan Smith", "first tech")
        T.Eq(c.Value("techId"), "T12345", "first id")
        T.Eq(c.Value("jobNumber"), "88412", "first job")
        T.Eq(c.Value("workOrder"), "55-2231", "first work order")
        T.Eq(c.Value("address"), "123 Example St, Mockville", "first address")
        for id in CallContext.REQUIRED
            T.Eq(c.Status(id), "mock", id " is mock")
        seen := Map()
        for row in MockProvider.JOBS {
            T.False(seen.Has(row[3]), "job number unique " row[3])
            seen[row[3]] := true
        }
        T.False(p.Running, "not running before Start")
        p.Start()
        T.True(p.Running, "running after Start")
        p.Stop()
        T.False(p.Running, "stopped")
    }

    static NewCall() {
        p := MockProvider()
        order := [], jobs := []
        p.OnContextChanged((ctx) => order.Push("changed"))
        p.OnNewCall((ctx) => (order.Push("new"), jobs.Push(ctx.Value("jobNumber"))))
        p.FireNewCall()
        T.Eq(order.Length, 2, "both events raised")
        T.Eq(order[1], "changed", "context changed first")
        T.Eq(order[2], "new", "then new call")
        T.Eq(jobs[1], "88390", "second job delivered")
        T.Eq(p.GetContext().Value("jobNumber"), "88390", "context moved to the next job")
        n := MockProvider.JOBS.Length
        loop n
            p.FireNewCall()
        T.Eq(p.GetContext().Value("jobNumber"), "88390", "wraps around after a full cycle")
    }

    static Duplicate() {
        p := MockProvider()
        ch := [0], nc := [0], jobs := []
        p.OnContextChanged((ctx) => ch[1] += 1)
        p.OnNewCall((ctx) => (nc[1] += 1, jobs.Push(ctx.Value("jobNumber"))))
        p.FireDuplicate()
        T.Eq(nc[1], 1, "duplicate raises one new-call event")
        T.Eq(ch[1], 0, "duplicate raises no context change")
        T.Eq(jobs[1], "88412", "same job")
    }

    static Burst() {
        p := MockProvider()
        nc := [0], jobs := Map()
        p.OnNewCall((ctx) => (nc[1] += 1, jobs[ctx.Value("jobNumber")] := true))
        p.FireBurst()
        T.Eq(nc[1], 5, "default burst raises five events")
        T.Eq(jobs.Count, 1, "all on the same job")
        p.FireBurst(3)
        T.Eq(nc[1], 8, "burst of three adds three")
    }

    static States() {
        p := MockProvider()
        ch := [0]
        p.OnContextChanged((ctx) => ch[1] += 1)
        T.True(p.SetFieldState("address", "unavailable"), "set unavailable")
        c := p.GetContext()
        T.Eq(c.Status("address"), "unavailable", "address unavailable")
        T.Eq(c.Value("address"), "", "unavailable has no value")
        T.Eq(c.Status("techName"), "mock", "others unchanged")
        p.SetFieldState("techName", "stale")
        c := p.GetContext()
        T.Eq(c.Status("techName"), "stale", "stale status")
        T.Eq(c.Value("techName"), "Jordan Smith", "stale keeps the value")
        p.SetFieldState("jobNumber", "empty")
        T.Eq(p.GetContext().Status("jobNumber"), "empty", "empty status")
        p.SetFieldState("address", "normal")
        T.Eq(p.GetContext().Status("address"), "mock", "back to normal")
        T.Eq(ch[1], 4, "each change raised a context event")
        T.False(p.SetFieldState("bogusField", "stale"), "unknown field refused")
        T.False(p.SetFieldState("address", "weird"), "unknown state refused")
        p.FireNewCall()
        T.Eq(p.GetContext().Status("techName"), "mock", "new call resets field states")
    }

    static Health() {
        p := MockProvider()
        ch := [0]
        p.OnContextChanged((ctx) => ch[1] += 1)
        T.True(p.Health().Ok, "healthy by default")
        T.True(p.Health().Message != "", "has a message")
        p.SetHealthy(false)
        h := p.Health()
        T.False(h.Ok, "unhealthy")
        T.True(h.Message != "", "unhealthy message")
        T.Eq(ch[1], 1, "health change raised a context event")
        p.SetHealthy(true)
        T.True(p.Health().Ok, "healthy again")
    }

    static Subscribers() {
        lg := Log({Path: TestMockProvider.Root "\sub.log", Level: "debug"})
        p := MockProvider({Logger: lg})
        got := []
        p.OnNewCall((ctx) => got.Push("a"))
        p.OnNewCall(ObjBindMethod(TestMockProvider, "Boom"))
        p.OnNewCall((ctx) => got.Push("c"))
        p.OnContextChanged(ObjBindMethod(TestMockProvider, "Boom"))
        p.OnContextChanged((ctx) => got.Push("d"))
        p.FireNewCall()
        T.Eq(got.Length, 3, "other subscribers still ran")
        T.True(got[1] = "d" && got[2] = "a" && got[3] = "c", "order kept around the failing subscriber")
        T.Contains(FileRead(lg.Path), "subscriber failed", "the failure was logged")
    }

    static Redaction() {
        lg := Log({Path: TestMockProvider.Root "\red.log", Level: "debug"})
        p := MockProvider({Logger: lg})
        p.GetContext()
        text := lg.Redact("Jordan Smith T12345 88412 55-2231 123 Example St, Mockville first=Jordan")
        for v in ["Jordan", "Smith", "T12345", "88412", "55-2231", "Example", "Mockville"]
            T.NotContains(text, v, "registered and redacted: " v)
        p.FireNewCall()
        text := lg.Redact("Casey Rivera 88390 42 Sample Ave, Faketown")
        for v in ["Casey", "Rivera", "88390", "Faketown"]
            T.NotContains(text, v, "next tech registered when it appears: " v)
    }

    static BaseClass() {
        b := ContextProvider()
        T.Eq(b.Kind, "none", "base kind")
        T.True(b.Health().Ok, "base health")
        T.Eq(b.GetContext().Ids().Length, 5, "base context has the required fields")
    }
}
