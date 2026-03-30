### TASK-42: Migrate all stores from ObservableObject to @Observable
**Epic:** Architecture
**Why:** Mixed `@Observable` and `ObservableObject` is the #1 performance issue. Every `@ObservedObject` store triggers full view rebuilds on ANY `@Published` change. CommandCenterView alone re-renders on 10+ properties it doesn't read.
**Stores to migrate:** CompassStore, HeartbeatStore, DispatchActivityStore, BrainFileStore, CentralBrainStore, BriefingStore, SystemHealthStore, StarfleetStore, QualityRouter, BrainIndexer, TicketStore (11 stores).

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
