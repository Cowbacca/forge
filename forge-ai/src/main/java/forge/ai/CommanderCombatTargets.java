package forge.ai;

import forge.game.GameEntity;
import forge.game.GameRules;
import forge.game.GameType;
import forge.game.card.Card;
import forge.game.card.CardCollection;
import forge.game.combat.AttackConstraints;
import forge.game.combat.Combat;
import forge.game.combat.CombatUtil;
import forge.game.player.GameLossReason;
import forge.game.player.Player;
import forge.game.player.PlayerCollection;
import forge.util.AITimeoutTracker;

import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

final class CommanderCombatTargets {
    private record Threat(Player player, int score) {}
    private record AttackTarget(Player player, int assignedDamage) {}

    private final List<Threat> rankedOpponents;
    private final List<Player> leadingOpponents;
    private final int lowestScore;
    private final int closeThreatMargin;

    static CommanderCombatTargets forPlayer(Player ai) {
        GameRules rules = ai.getGame().getRules();
        PlayerCollection players = ai.getGame().getPlayers();
        if (!ai.getController().isAI() || players.size() < 3 || !rules.hasAppliedVariant(GameType.Commander)
                || rules.getGameType() == GameType.CommanderDraft || rules.hasSharedTeamTurns()
                || players.anyMatch(player -> !player.getAllies().isEmpty())) {
            return null;
        }
        return new CommanderCombatTargets(ai);
    }

    private CommanderCombatTargets(Player ai) {
        rankedOpponents = ai.getOpponents().stream()
                .map(player -> new Threat(player, ComputerUtil.evaluateBoardPosition(ai, player)))
                .sorted(Comparator.comparingInt(Threat::score).reversed()
                        .thenComparing(Comparator.comparingInt((Threat threat) -> threat.player().getLife()).reversed()))
                .toList();
        int highestScore = rankedOpponents.get(0).score();
        lowestScore = rankedOpponents.get(rankedOpponents.size() - 1).score();
        closeThreatMargin = Math.max(40, highestScore / 8);
        leadingOpponents = rankedOpponents.stream()
                .filter(threat -> highestScore - threat.score() <= closeThreatMargin)
                .map(Threat::player)
                .toList();
    }

    List<Player> opponentsInThreatOrder() {
        return rankedOpponents.stream().map(Threat::player).toList();
    }

    boolean isMajorThreat(Player player) {
        return leadingOpponents.contains(player) && rankedOpponents.stream()
                .anyMatch(threat -> threat.player().equals(player) && threat.score() - lowestScore > closeThreatMargin);
    }

    void balanceAttacks(Combat combat) {
        AttackConstraints constraints = combat.getAttackConstraints();
        Map<Card, GameEntity> assigned = new LinkedHashMap<>(combat.getAttackersAndDefenders());
        int violations = constraints.countViolations(assigned);
        if (violations < 0) {
            return;
        }

        Map<Player, List<Card>> blockers = new HashMap<>();
        for (Card attacker : combat.getAttackers()) {
            AITimeoutTracker.check();
            if (!(assigned.get(attacker) instanceof Player original)) {
                continue;
            }
            boolean spare = !isMajorThreat(original) && couldEliminate(original, combat.getAttackersOf(original));
            for (Player target : alternativeTargets(combat, attacker, original, spare)) {
                if (canRedirect(combat, attacker, target, blockers)
                        && tryAssignment(assigned, attacker, target, constraints, violations)) {
                    combat.removeFromCombat(attacker);
                    combat.addAttacker(attacker, target);
                    break;
                }
            }
            if (spare && assigned.get(attacker) == original
                    && tryAssignment(assigned, attacker, null, constraints, violations)) {
                combat.removeFromCombat(attacker);
            }
        }
    }

    private List<Player> alternativeTargets(Combat combat, Card attacker, Player original, boolean spare) {
        CardCollection otherAttackers = combat.getAttackersOf(original);
        otherAttackers.remove(attacker);
        int originalDamage = ComputerUtilCombat.sumDamageIfUnblocked(otherAttackers, original);
        return leadingOpponents.stream()
                .filter(player -> !player.equals(original) && combat.getDefenders().contains(player))
                .map(player -> new AttackTarget(player, ComputerUtilCombat.sumDamageIfUnblocked(combat.getAttackersOf(player), player)))
                .filter(target -> spare || !leadingOpponents.contains(original) || target.assignedDamage() < originalDamage)
                .sorted(Comparator.comparingInt(AttackTarget::assignedDamage))
                .map(AttackTarget::player)
                .toList();
    }

    private boolean canRedirect(Combat combat, Card attacker, Player target, Map<Player, List<Card>> blockers) {
        return CombatUtil.canAttack(attacker, target)
                && CombatUtil.getAttackCost(attacker.getGame(), attacker, target) == null
                && AiAttackController.lifeLostPerAttacker(target) == 0
                && !AiAttackController.feedsAttackTriggeredTokens(attacker.getController(), target)
                && ComputerUtilCombat.damageIfUnblocked(attacker, target, null, false) > 0
                && blockers.computeIfAbsent(target, AiAttackController::getOpponentCreatures).stream()
                        .noneMatch(blocker -> CombatUtil.canBlock(attacker, blocker))
                && permitsAdditionalAttacker(combat, attacker, target);
    }

    boolean permitsAdditionalAttacker(Combat combat, Card attacker, Player target) {
        if (isMajorThreat(target)) {
            return true;
        }
        CardCollection attackers = combat.getAttackersOf(target);
        attackers.add(attacker);
        return !couldEliminate(target, attackers);
    }

    private static boolean tryAssignment(Map<Card, GameEntity> assigned, Card attacker, Player target,
                                         AttackConstraints constraints, int violations) {
        GameEntity original = target == null ? assigned.remove(attacker) : assigned.put(attacker, target);
        int changed = constraints.countViolations(assigned);
        if (changed >= 0 && changed <= violations) {
            return true;
        }
        assigned.put(attacker, original);
        return false;
    }

    private static boolean couldEliminate(Player defender, List<Card> attackers) {
        return (ComputerUtilCombat.sumDamageIfUnblocked(attackers, defender) >= defender.getLife()
                    && !defender.cantLoseForZeroOrLessLife())
                || (ComputerUtilCombat.sumPoisonIfUnblocked(attackers, defender) + defender.getPoisonCounters()
                    >= defender.getGame().getRules().getPoisonCountersToLose() && !defender.cantLoseCheck(GameLossReason.Poisoned))
                || (attackers.stream().anyMatch(attacker -> attacker.isCommander()
                    && defender.getCommanderDamage(attacker) + commanderDamageIfUnblocked(attacker, defender) >= 21)
                    && !defender.cantLoseCheck(GameLossReason.CommanderDamage));
    }

    private static int commanderDamageIfUnblocked(Card commander, Player defender) {
        int power = commander.getNetCombatDamage()
                + ComputerUtilCombat.predictPowerBonusOfAttacker(commander, null, null, false);
        int damage = ComputerUtilCombat.predictDamageTo(defender, power, commander, true);
        return commander.hasDoubleStrike() ? 2 * damage : damage;
    }
}
