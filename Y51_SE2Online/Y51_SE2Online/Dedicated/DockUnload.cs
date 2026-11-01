using System;
using System.Collections.Generic;
using System.Linq;
using Keen.Game2.Simulation.WorldObjects.CubeBlocks;
using Keen.Game2.Simulation.WorldObjects.CubeBlocks.MechanicalBlocks;
using Keen.Game2.Simulation.WorldObjects.CubeGrids;
using Keen.Game2.Simulation.WorldObjects.Items;
using Keen.VRage.Core;
using Keen.VRage.Core.Game.Components;
using Keen.VRage.Core.Game.Systems;
using Keen.VRage.DCS.Components;
using Keen.VRage.Library.Mathematics;
using Y51_SE2Online.Core;

namespace Y51_SE2Online.Dedicated;

/// <summary>
/// Dedicated-server workaround for docked-grid inventory transfer. Exactly one connected connector must have Eject Items
/// enabled; that connector's grid is the source and the other grid is the destination. No game conveyor/ejection system is patched.
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
            var cube = grid.TryGet<CubeGridComponent>();
            if (cube == null) continue;

            cube.VisitAllBlocksWithComponent((CubeBlockComponent block) =>
            {
                if (block.Entity.TryGet<ConnectorComponent>() is not { IsConnected: true, ConnectedEntity: { } remoteConnector }) return;
                // Process each locked pair once. The eject setting selects direction; equal settings mean no transfer.
                if (string.CompareOrdinal(block.Entity.ToString(), remoteConnector.ToString()) >= 0) return;
                var localEjector = block.Entity.TryGet<ItemEjectorComponent>();
                var remoteEjector = remoteConnector.TryGet<ItemEjectorComponent>();
                if (localEjector == null || remoteEjector == null || localEjector.IsEnabled == remoteEjector.IsEnabled) return;

                Entity remoteGrid = Y51_SE2Online.SyncEngine.WorldSocial.GridOf(remoteConnector);
                if (remoteGrid == null || remoteGrid == grid || remoteGrid.TryGet<CubeGridComponent>() == null) return;

                Entity sourceGrid = localEjector.IsEnabled ? grid : remoteGrid;
                Entity targetGrid = localEjector.IsEnabled ? remoteGrid : grid;
                var sourceCube = sourceGrid.TryGet<CubeGridComponent>();
                var targetCube = targetGrid.TryGet<CubeGridComponent>();
                if (sourceCube == null || targetCube == null) return;
                var sourceInventories = CargoInventories(sourceCube, includeConnector: true);
                var targetInventories = CargoInventories(targetCube, includeConnector: true);
                if (sourceInventories.Count == 0 || targetInventories.Count == 0) return;

                int moved = Unload(sourceInventories, targetInventories);
                if (moved > 0)
                {
                    string pair = block.Entity + "->" + remoteConnector;
                    if (LoggedPairs.Add(pair))
                        GameLog.Instance.Info($"dedicated: connector auto-transfer moved {moved} item stacks from {sourceGrid} to {targetGrid}; direction selected by the single enabled Eject Items setting");
                }
            });
        }
    }

    private static int Unload(List<InventoryComponent> sources, List<InventoryComponent> targets)
    {
        int movedStacks = 0;
        foreach (var source in sources)
        {
            // Snapshot because successful transfers mutate the inventory's item list.
            foreach (var stack in source.Items.ToArray())
            {
                FixedPoint remaining = stack.Amount;
                foreach (var target in targets)
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

    private static List<InventoryComponent> CargoInventories(CubeGridComponent cube, bool includeConnector = false)
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
