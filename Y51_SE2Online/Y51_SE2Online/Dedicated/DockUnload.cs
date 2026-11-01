using System;
using System.Collections.Generic;
using System.Linq;
using Keen.Game2.Simulation.WorldObjects.CubeBlocks;
using Keen.Game2.Simulation.WorldObjects.CubeGrids;
using Keen.Game2.Simulation.WorldObjects.CubeGrids.Physicss;
using Keen.Game2.Simulation.WorldObjects.Items;
using Keen.VRage.Core;
using Keen.VRage.Core.Game.Components;
using Keen.VRage.Core.Game.Systems;
using Keen.VRage.Library.Mathematics;

namespace Y51_SE2Online.Dedicated;

/// <summary>
/// Dedicated-server workaround for SE2's missing automatic dock unloading. When enabled, cargo inventories on a moving
/// grid and its connector are moved into cargo containers on the connected static grid. It never uses connector ejection.
/// </summary>
internal static class DockUnload
{
    private const long ScanIntervalMs = 2000;
    private static long _nextScanMs;
    private static readonly HashSet<string> LoggedPairs = new(StringComparer.Ordinal);

    public static void Tick(Session session)
    {
        if (!DedicatedRuntime.Requested || DedicatedRuntime.Config?.AutoUnloadDockedShips != true) return;
        long now = Environment.TickCount64;
        if (now < _nextScanMs) return;
        _nextScanMs = now + ScanIntervalMs;

        try { Scan(session); }
        catch (Exception ex) { GameLog.Instance.WarnOnce("dedicated-dock-unload", "dedicated: dock auto-unload scan failed; automatic unloading is paused for this scan: " + ex); }
    }

    private static void Scan(Session session)
    {
        foreach (Entity grid in session.GetEntitiesOfType<CubeGridComponent>())
        {
            if (grid.TryGet<GridPhysicsComponent>()?.GridMotionType != Keen.VRage.Physics.Data.BodyArgs.Motion.Static) continue;
            var cube = grid.TryGet<CubeGridComponent>();
            if (cube == null) continue;

            var receivingCargo = CargoInventories(grid, cube);
            if (receivingCargo.Count == 0) continue;

            cube.VisitAllBlocksWithComponent((CubeBlockComponent block) =>
            {
                if (block.Entity.TryGet<ConnectorComponent>() is not { IsConnected: true, ConnectedEntity: { } remoteConnector }) return;
                Entity remoteGrid = Y51_SE2Online.SyncEngine.WorldSocial.GridOf(remoteConnector);
                if (remoteGrid == null || remoteGrid == grid || remoteGrid.TryGet<CubeGridComponent>() == null) return;
                if (remoteGrid.TryGet<GridPhysicsComponent>()?.GridMotionType == Keen.VRage.Physics.Data.BodyArgs.Motion.Static) return;

                int moved = Unload(remoteGrid, receivingCargo);
                if (moved > 0)
                {
                    string pair = grid.ToString() + "<-" + remoteGrid;
                    if (LoggedPairs.Add(pair))
                        GameLog.Instance.Info($"dedicated: dock auto-unload enabled for connected ship {remoteGrid} into static grid {grid}; transferred {moved} item stacks so far");
                }
            });
        }
    }

    private static int Unload(Entity sourceGrid, List<InventoryComponent> receivingCargo)
    {
        var sourceCube = sourceGrid.TryGet<CubeGridComponent>();
        if (sourceCube == null) return 0;
        var sources = CargoInventories(sourceGrid, sourceCube, includeConnector: true);
        int movedStacks = 0;
        foreach (var source in sources)
        {
            // Snapshot because successful transfers mutate the inventory's item list.
            foreach (var stack in source.Items.ToArray())
            {
                FixedPoint remaining = stack.Amount;
                foreach (var target in receivingCargo)
                {
                    if (remaining <= FixedPoint.Zero) break;
                    FixedPoint amount = source.TransferByDef(target, stack.Definition, null, remaining, allowPartial: true);
                    if (amount > FixedPoint.Zero) remaining -= amount;
                }
                if (remaining < stack.Amount) movedStacks++;
            }
        }
        return movedStacks;
    }

    private static List<InventoryComponent> CargoInventories(Entity grid, CubeGridComponent cube, bool includeConnector = false)
    {
        var result = new List<InventoryComponent>();
        cube.VisitAllBlocksWithComponent((CubeBlockComponent block) =>
        {
            string name = block.Entity.GetComposition()?.DebugNameShort ?? "";
            bool cargo = name.Contains("CargoContainer", StringComparison.OrdinalIgnoreCase);
            bool connector = includeConnector && block.Entity.TryGet<ConnectorComponent>() != null;
            if (!cargo && !connector) return;
            result.AddRange(block.Entity.Components.OfType<InventoryComponent>());
        });
        return result.Distinct().ToList();
    }
}
