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
    private const long DiagnosticLogIntervalMs = 15000;
    private const long ScanSummaryIntervalMs = 60000;
    private static long _nextScanMs;
    private static long _lastInactiveLogMs;
    private static long _lastScanSummaryMs;
    private static readonly Dictionary<string, long> LoggedPairs = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, long> LoggedPairPlans = new(StringComparer.Ordinal);

    public static void Tick(Session session)
    {
        long now = Environment.TickCount64;
        if (!DedicatedRuntime.Requested) return;
        if (DedicatedRuntime.Config?.AutoUnloadDockedShips != true)
        {
            if (now - _lastInactiveLogMs >= 60000)
            {
                _lastInactiveLogMs = now;
                GameLog.Instance.Info("dedicated: connector auto-transfer inactive; AutoUnloadDockedShips is false or missing in the loaded server configuration");
            }
            return;
        }
        if (now < _nextScanMs) return;
        _nextScanMs = now + ScanIntervalMs;

        try { Scan(session); }
        catch (Exception ex) { GameLog.Instance.WarnOnce("dedicated-dock-unload", "dedicated: dock auto-unload scan failed; automatic unloading is paused for this scan: " + ex); }
    }

    private static void Scan(Session session)
    {
        var handledConnectedPairs = new HashSet<string>(StringComparer.Ordinal);
        var handledUndockedConnectors = new HashSet<string>(StringComparer.Ordinal);
        int connectorsSeen = 0;
        int connectedConnectorsSeen = 0;
        foreach (Entity grid in session.GetEntitiesOfType<CubeGridComponent>())
        {
            var cube = grid.TryGet<CubeGridComponent>();
            if (cube == null) continue;

            cube.VisitAllBlocksWithComponent((CubeBlockComponent block) =>
            {
                var connector = block.Entity.TryGet<ConnectorComponent>();
                if (connector == null) return;
                connectorsSeen++;
                var localEjector = block.Entity.TryGet<ItemEjectorComponent>();
                if (connector.IsConnected && connector.ConnectedEntity is { } remoteConnector)
                {
                    connectedConnectorsSeen++;
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

        long now = Environment.TickCount64;
        if (now - _lastScanSummaryMs >= ScanSummaryIntervalMs)
        {
            _lastScanSummaryMs = now;
            GameLog.Instance.Info($"dedicated: connector auto-transfer scan active; connector blocks seen={connectorsSeen}, connected endpoints seen={connectedConnectorsSeen}, unique connected pairs={handledConnectedPairs.Count}");
        }
    }

    private static void ProcessConnectedPair(Entity localConnector, ItemEjectorComponent localEjector, Entity remoteConnector)
    {
        // Process each locked pair once. The eject setting selects direction; equal settings mean no transfer.
        if (string.CompareOrdinal(localConnector.ToString(), remoteConnector.ToString()) >= 0) return;
        var remoteEjector = remoteConnector.TryGet<ItemEjectorComponent>();
        if (localEjector == null || remoteEjector == null) return;

        string pairKey = $"{localConnector}|{remoteConnector}";
        string stateKey = $"{pairKey}|{localEjector.IsEnabled}|{remoteEjector.IsEnabled}";
        if (ShouldLog(LoggedPairPlans, stateKey, Environment.TickCount64))
            GameLog.Instance.Info($"dedicated: connector pair state: local {localConnector} eject={localEjector.IsEnabled}; remote {remoteConnector} eject={remoteEjector.IsEnabled}; {(localEjector.IsEnabled == remoteEjector.IsEnabled ? "transfer disabled (both settings match)" : "transfer direction follows the connector set to eject")}");
        if (localEjector.IsEnabled == remoteEjector.IsEnabled) return;

        var localBlock = localConnector.TryGet<CubeBlockComponent>();
        var remoteBlock = remoteConnector.TryGet<CubeBlockComponent>();
        Entity localGrid = localBlock?.Grid?.Entity;
        Entity remoteGrid = remoteBlock?.Grid?.Entity;
        if (localGrid == null || remoteGrid == null || remoteGrid == localGrid) return;

        Entity sourceGrid = localEjector.IsEnabled ? localGrid : remoteGrid;
        Entity targetGrid = localEjector.IsEnabled ? remoteGrid : localGrid;
        Entity sourceConnector = localEjector.IsEnabled ? localConnector : remoteConnector;
        Entity targetConnector = localEjector.IsEnabled ? remoteConnector : localConnector;
        string plan = $"{stateKey}|{localGrid}|{remoteGrid}";
        if (ShouldLog(LoggedPairPlans, plan, Environment.TickCount64))
            GameLog.Instance.Info($"dedicated: connector transfer plan: local {localConnector} eject={localEjector.IsEnabled} grid={localGrid}; remote {remoteConnector} eject={remoteEjector.IsEnabled} grid={remoteGrid}; source {sourceConnector} grid={sourceGrid}; destination {targetConnector} grid={targetGrid}");
        var sourceCube = sourceGrid.TryGet<CubeGridComponent>();
        var targetCube = targetGrid.TryGet<CubeGridComponent>();
        if (sourceCube == null || targetCube == null) return;
        var sourceAnchor = ConnectorInventory(sourceConnector);
        var targetAnchor = ConnectorInventory(targetConnector);
        if (sourceAnchor == null || targetAnchor == null) return;

        // Keep the known-working cargo/cockpit/connector inventory selection. On a base side, restrict the
        // transfer endpoints to cargo containers; on a vessel side, also include cockpit and storage blocks.
        bool sourceIsVessel = HasCockpit(sourceCube);
        bool targetIsVessel = HasCockpit(targetCube);
        var sourceCandidates = TransferInventories(sourceCube, sourceConnector, sourceIsVessel);
        var targetCandidates = TransferInventories(targetCube, targetConnector, targetIsVessel);
        if (sourceCandidates.Count == 0 || targetCandidates.Count == 0) return;

        int loaded = TransferIntoConnector(sourceCandidates, sourceAnchor);
        int crossed = TransferConnectorToConnector(sourceAnchor, targetAnchor);
        int unloaded = TransferOutOfConnector(targetAnchor, targetCandidates);
        string routeKey = $"{sourceConnector}->{targetConnector}|{sourceGrid}->{targetGrid}";
        if (ShouldLog(LoggedPairs, routeKey, Environment.TickCount64))
            GameLog.Instance.Info($"dedicated: connector route {sourceGrid} storage->connector {sourceConnector}: {loaded} stacks; connector {sourceConnector}->{targetConnector}: {crossed} stacks; connector {targetConnector}->storage {targetGrid}: {unloaded} stacks; candidate inventories source={sourceCandidates.Count} destination={targetCandidates.Count}; source conveyor={(sourceAnchor.ConveyorSystem != null)} destination conveyor={(targetAnchor.ConveyorSystem != null)}");
    }

    private static int TransferIntoConnector(List<InventoryComponent> sourceCandidates, InventoryComponent sourceAnchor)
    {
        int movedStacks = 0;
        var reachableByItem = new Dictionary<ItemDefinition, HashSet<InventoryComponent>>();
        foreach (var source in sourceCandidates)
        {
            if (source == sourceAnchor) continue;
            foreach (var stack in source.Items.ToArray())
            {
                if (!reachableByItem.TryGetValue(stack.Definition, out var reachable))
                {
                    reachable = new HashSet<InventoryComponent>(ReachableInventories(sourceAnchor, stack.Definition));
                    reachableByItem.Add(stack.Definition, reachable);
                }
                if (!reachable.Contains(source)) continue;
                FixedPoint amount = source.TransferByDef(sourceAnchor, stack.Definition, null, stack.Amount, allowPartial: true);
                if (amount > FixedPoint.Zero) movedStacks++;
            }
        }
        return movedStacks;
    }

    private static int TransferConnectorToConnector(InventoryComponent sourceAnchor, InventoryComponent targetAnchor)
    {
        int movedStacks = 0;
        foreach (var stack in sourceAnchor.Items.ToArray())
        {
            FixedPoint amount = sourceAnchor.TransferByDef(targetAnchor, stack.Definition, null, stack.Amount, allowPartial: true);
            if (amount > FixedPoint.Zero) movedStacks++;
        }
        return movedStacks;
    }

    private static int TransferOutOfConnector(InventoryComponent targetAnchor, List<InventoryComponent> targetCandidates)
    {
        int movedStacks = 0;
        var reachableByItem = new Dictionary<ItemDefinition, HashSet<InventoryComponent>>();
        foreach (var stack in targetAnchor.Items.ToArray())
        {
            if (!reachableByItem.TryGetValue(stack.Definition, out var reachable))
            {
                reachable = new HashSet<InventoryComponent>(ReachableInventories(targetAnchor, stack.Definition));
                reachableByItem.Add(stack.Definition, reachable);
            }
            FixedPoint remaining = stack.Amount;
            foreach (var target in targetCandidates)
            {
                if (target == targetAnchor || !reachable.Contains(target) || remaining <= FixedPoint.Zero) continue;
                FixedPoint amount = targetAnchor.TransferByDef(target, stack.Definition, null, remaining, allowPartial: true);
                if (amount > FixedPoint.Zero) remaining -= amount;
            }
            if (remaining < stack.Amount) movedStacks++;
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
            if (ShouldLog(LoggedPairs, key, Environment.TickCount64))
                GameLog.Instance.Info($"dedicated: returned {movedStacks} item stacks from undocked connector {connectorEntity} to the nearest reachable cargo containers; any remainder stays in the connector and will be retried");
        }
    }

    private static List<InventoryComponent> ReachableInventories(InventoryComponent anchor, ItemDefinition item)
    {
        var result = new List<InventoryComponent>();
        if (anchor == null) return result;
        // The game's iterator may return only inventories reached through graph edges, omitting the starting
        // connector inventory itself. Include that endpoint so items already inside a connector can transfer too.
        result.Add(anchor);
        if (anchor.ConveyorSystem == null) return result;
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

    private static bool ShouldLog(Dictionary<string, long> lastLogged, string key, long now)
    {
        if (lastLogged.TryGetValue(key, out long previous) && now - previous < DiagnosticLogIntervalMs) return false;
        lastLogged[key] = now;
        return true;
    }

    private static List<InventoryComponent> TransferInventories(CubeGridComponent cube, Entity connector, bool vessel)
    {
        if (!vessel)
            return CargoInventories(cube);

        var result = CargoInventories(cube, includedConnector: connector, includeCockpits: true);
        // Include other named storage blocks without treating every machine inventory as a transfer endpoint.
        cube.VisitAllBlocksWithComponent((CubeBlockComponent block) =>
        {
            string name = block.Entity.GetComposition()?.DebugNameShort ?? "";
            bool storage = name.Contains("Storage", StringComparison.OrdinalIgnoreCase) ||
                           name.Contains("Container", StringComparison.OrdinalIgnoreCase) ||
                           name.Contains("Cargo", StringComparison.OrdinalIgnoreCase);
            if (storage) result.AddRange(block.Entity.Components.OfType<InventoryComponent>());
        });
        // Composite-grid traversal can omit a connector block; include its own inventory on vessel sides.
        var connectorInventory = ConnectorInventory(connector);
        if (connectorInventory != null && !result.Contains(connectorInventory)) result.Add(connectorInventory);
        return result.Distinct().ToList();
    }

    private static bool HasCockpit(CubeGridComponent cube)
    {
        bool found = false;
        cube.VisitAllBlocksWithComponent((CubeBlockComponent block) =>
        {
            if (block.Entity.TryGet<CockpitComponent>() != null) found = true;
        });
        return found;
    }

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
