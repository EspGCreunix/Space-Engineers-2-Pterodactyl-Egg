using System;
using System.Collections.Generic;
using System.Linq;
using Keen.Game2.Simulation.WorldObjects.CubeBlocks;
using Keen.Game2.Simulation.WorldObjects.CubeBlocks.MechanicalBlocks;
using Keen.Game2.Simulation.WorldObjects.CubeGrids;
using Keen.Game2.Simulation.WorldObjects.CubeGrids.ResourceDistribution.Conveyors;
using Keen.Game2.Simulation.WorldObjects.Items;
using Keen.VRage.Core;
using Keen.VRage.Core.Game.Components;
using Keen.VRage.Core.Game.Data;
using Keen.VRage.Core.Game.Systems;
using Keen.VRage.DCS.Components;
using Keen.VRage.Library.Mathematics;
using Y51_SE2Online.Core;

namespace Y51_SE2Online.Dedicated;

/// <summary>
/// Dedicated-server workaround for connector inventory transfer. Exactly one connected connector must have Eject Items
/// enabled; that connector's grid is the source and the other grid is the destination. Transfers stay within the conveyor
/// network reachable from each connector. When a connector is undocked with Eject Items off, its contents are returned to
/// the nearest reachable cargo container on its own grid. No game conveyor/ejection system is patched.
/// </summary>
internal static class DockUnload
{
    private const long ScanIntervalMs = 2000;
    private static long _nextScanMs;
    private static readonly HashSet<string> LoggedPairs = new(StringComparer.Ordinal);
    private static readonly HashSet<string> LoggedPairPlans = new(StringComparer.Ordinal);

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
        var handledConnectedPairs = new HashSet<string>(StringComparer.Ordinal);
        var handledUndockedConnectors = new HashSet<string>(StringComparer.Ordinal);
        foreach (Entity grid in session.GetEntitiesOfType<CubeGridComponent>())
        {
            var cube = grid.TryGet<CubeGridComponent>();
            if (cube == null) continue;

            cube.VisitAllBlocksWithComponent((CubeBlockComponent block) =>
            {
                var connector = block.Entity.TryGet<ConnectorComponent>();
                if (connector == null) return;
                var localEjector = block.Entity.TryGet<ItemEjectorComponent>();
                if (connector.IsConnected && connector.ConnectedEntity is { } remoteConnector)
                {
                    string first = block.Entity.ToString();
                    string second = remoteConnector.ToString();
                    string pairKey = string.CompareOrdinal(first, second) < 0 ? first + "|" + second : second + "|" + first;
                    if (handledConnectedPairs.Add(pairKey))
                        ProcessConnectedPair(block.Entity, localEjector, remoteConnector);
                    return;
                }

                // Items can remain in the connector inventory after it is undocked. Return them locally only when the
                // connector is not configured to eject into the world; inaccessible or full cargo stays in place to retry.
                if (localEjector?.IsEnabled == false && handledUndockedConnectors.Add(block.Entity.ToString()) &&
                    block.Entity.TryGet<CubeBlockComponent>()?.Grid is { } owningGrid)
                    ReturnUndockedConnectorItems(owningGrid, block.Entity);
            });
        }
    }

    private static void ProcessConnectedPair(Entity localConnector, ItemEjectorComponent localEjector, Entity remoteConnector)
    {
        // Process each locked pair once. The eject setting selects direction; equal settings mean no transfer.
        if (string.CompareOrdinal(localConnector.ToString(), remoteConnector.ToString()) >= 0) return;
        var remoteEjector = remoteConnector.TryGet<ItemEjectorComponent>();
        if (localEjector == null || remoteEjector == null || localEjector.IsEnabled == remoteEjector.IsEnabled) return;

        var localBlock = localConnector.TryGet<CubeBlockComponent>();
        var remoteBlock = remoteConnector.TryGet<CubeBlockComponent>();
        Entity localGrid = localBlock?.Grid?.Entity;
        Entity remoteGrid = remoteBlock?.Grid?.Entity;
        if (localGrid == null || remoteGrid == null || remoteGrid == localGrid) return;

        Entity sourceGrid = localEjector.IsEnabled ? localGrid : remoteGrid;
        Entity targetGrid = localEjector.IsEnabled ? remoteGrid : localGrid;
        Entity sourceConnector = localEjector.IsEnabled ? localConnector : remoteConnector;
        Entity targetConnector = localEjector.IsEnabled ? remoteConnector : localConnector;
        string plan = $"{localConnector}|{localEjector.IsEnabled}|{localGrid}|{remoteConnector}|{remoteEjector.IsEnabled}|{remoteGrid}";
        if (LoggedPairPlans.Add(plan))
            GameLog.Instance.Info($"dedicated: connector transfer plan: local {localConnector} eject={localEjector.IsEnabled} grid={localGrid}; remote {remoteConnector} eject={remoteEjector.IsEnabled} grid={remoteGrid}; source {sourceConnector} grid={sourceGrid}; destination {targetConnector} grid={targetGrid}");
        var sourceCube = sourceGrid.TryGet<CubeGridComponent>();
        var targetCube = targetGrid.TryGet<CubeGridComponent>();
        if (sourceCube == null || targetCube == null) return;
        var sourceAnchor = ConnectorInventory(sourceConnector);
        var targetAnchor = ConnectorInventory(targetConnector);
        if (sourceAnchor == null || targetAnchor == null) return;

        var sourceCandidates = CargoInventories(sourceCube, includedConnector: sourceConnector, includeCockpits: true);
        var targetCandidates = CargoInventories(targetCube, includedConnector: targetConnector, includeCockpits: true);
        if (sourceCandidates.Count == 0 || targetCandidates.Count == 0) return;

        int moved = TransferReachable(sourceCandidates, targetCandidates, sourceAnchor, targetAnchor);
        if (moved > 0)
        {
            string pair = localConnector + "->" + remoteConnector;
            if (LoggedPairs.Add(pair))
                GameLog.Instance.Info($"dedicated: connector auto-transfer moved {moved} item stacks from {sourceGrid} to {targetGrid}; only cargo reachable through the paired connectors' conveyor networks was considered");
        }
    }

    private static int TransferReachable(List<InventoryComponent> sourceCandidates, List<InventoryComponent> targetCandidates,
        InventoryComponent sourceAnchor, InventoryComponent targetAnchor)
    {
        int movedStacks = 0;
        var sourceReachability = new Dictionary<ItemDefinition, HashSet<InventoryComponent>>();
        var targetReachability = new Dictionary<ItemDefinition, HashSet<InventoryComponent>>();
        foreach (var source in sourceCandidates)
        {
            // Snapshot because successful transfers mutate the inventory's item list.
            foreach (var stack in source.Items.ToArray())
            {
                if (!sourceReachability.TryGetValue(stack.Definition, out var reachableSources))
                {
                    reachableSources = new HashSet<InventoryComponent>(ReachableInventories(sourceAnchor, stack.Definition));
                    sourceReachability.Add(stack.Definition, reachableSources);
                }
                if (!reachableSources.Contains(source)) continue;
                if (!targetReachability.TryGetValue(stack.Definition, out var reachableTargets))
                {
                    reachableTargets = new HashSet<InventoryComponent>(ReachableInventories(targetAnchor, stack.Definition));
                    targetReachability.Add(stack.Definition, reachableTargets);
                }
                FixedPoint remaining = stack.Amount;
                foreach (var target in targetCandidates)
                {
                    if (remaining <= FixedPoint.Zero) break;
                    if (!reachableTargets.Contains(target)) continue;
                    FixedPoint amount = source.TransferByDef(target, stack.Definition, null, remaining, allowPartial: true);
                    if (amount > FixedPoint.Zero) remaining -= amount;
                }
                if (remaining < stack.Amount) movedStacks++;
            }
        }
        return movedStacks;
    }

    private static void ReturnUndockedConnectorItems(CubeGridComponent cube, Entity connectorEntity)
    {
        var connectorInventory = ConnectorInventory(connectorEntity);
        if (connectorInventory == null || !connectorInventory.HasAnyItem()) return;
        var localCargo = CargoInventories(cube, excludedConnector: connectorEntity);
        if (localCargo.Count == 0) return;

        int movedStacks = 0;
        foreach (var stack in connectorInventory.Items.ToArray())
        {
            var reachable = ReachableInventories(connectorInventory, stack.Definition);
            var connectorBlock = connectorEntity.TryGet<CubeBlockComponent>();
            if (connectorBlock == null) return;
            var at = connectorBlock.Data.GetWorldTransform().Position;
            var nearestFirst = localCargo
                .Where(reachable.Contains)
                .OrderBy(inv => Vector3D.DistanceSquared(BlockPosition(inv), at));
            FixedPoint remaining = stack.Amount;
            foreach (var target in nearestFirst)
            {
                if (remaining <= FixedPoint.Zero) break;
                FixedPoint amount = connectorInventory.TransferByDef(target, stack.Definition, null, remaining, allowPartial: true);
                if (amount > FixedPoint.Zero) remaining -= amount;
            }
            if (remaining < stack.Amount) movedStacks++;
        }

        if (movedStacks > 0)
        {
            string key = "undocked:" + connectorEntity;
            if (LoggedPairs.Add(key))
                GameLog.Instance.Info($"dedicated: returned {movedStacks} item stacks from undocked connector {connectorEntity} to the nearest reachable cargo containers; any remainder stays in the connector and will be retried");
        }
    }

    private static List<InventoryComponent> ReachableInventories(InventoryComponent anchor, ItemDefinition item)
    {
        var result = new List<InventoryComponent>();
        if (anchor?.ConveyorSystem == null) return result;
        // The game's iterator may return only inventories reached through graph edges, omitting the starting
        // connector inventory itself. Include that endpoint so items already inside a connector can transfer too.
        result.Add(anchor);
        foreach (var inventory in ConveyorSystemComponent.IterateReachableInventories(anchor, item, followEdgeDirection: false, mustContainTheItem: false))
            if (inventory != null && !result.Contains(inventory)) result.Add(inventory);
        return result;
    }

    private static Vector3D BlockPosition(InventoryComponent inventory)
    {
        var block = inventory?.Entity.TryGet<CubeBlockComponent>();
        return block?.Data.GetWorldTransform().Position ?? default;
    }

    private static InventoryComponent ConnectorInventory(Entity connector) =>
        connector?.Components.OfType<InventoryComponent>().FirstOrDefault();

    private static List<InventoryComponent> CargoInventories(CubeGridComponent cube, Entity includedConnector = null,
        Entity excludedConnector = null, bool includeCockpits = false)
    {
        var result = new List<InventoryComponent>();
        cube.VisitAllBlocksWithComponent((CubeBlockComponent block) =>
        {
            string name = block.Entity.GetComposition()?.DebugNameShort ?? "";
            bool cargo = name.Contains("CargoContainer", StringComparison.OrdinalIgnoreCase);
            bool connector = includedConnector != null && block.Entity == includedConnector;
            bool cockpit = includeCockpits && block.Entity.TryGet<CockpitComponent>() != null;
            if (excludedConnector != null && block.Entity == excludedConnector) return;
            if (!cargo && !connector && !cockpit) return;
            result.AddRange(block.Entity.Components.OfType<InventoryComponent>());
        });
        return result.Distinct().ToList();
    }
}
