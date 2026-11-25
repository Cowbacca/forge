package forge.ai.attacking;

import forge.ai.AITest;
import forge.ai.LobbyPlayerAi;
import forge.deck.Deck;
import forge.game.Game;
import forge.game.GameRules;
import forge.game.GameStage;
import forge.game.GameType;
import forge.game.Match;
import forge.game.card.Card;
import forge.game.combat.Combat;
import forge.game.combat.CombatUtil;
import forge.game.phase.PhaseType;
import forge.game.player.Player;
import forge.game.player.RegisteredPlayer;
import org.testng.annotations.Test;

import java.util.List;
import java.util.stream.IntStream;

import static org.testng.AssertJUnit.assertEquals;
import static org.testng.AssertJUnit.assertTrue;

public class CommanderAttackTests extends AITest {
    @Test
    public void attacksTheStrongerBoardDespiteAnEasyKnockout() {
        Game game = gameWithPlayers(GameType.Commander, 3);
        Player ai = game.getPlayers().get(0);
        Player weak = game.getPlayers().get(1);
        Player strong = game.getPlayers().get(2);
        weak.setLife(2, null);
        addCard("Gilded Lotus", strong);
        addCard("Grizzly Bears", ai).setSickness(false);

        Combat combat = declareAttackers(ai);

        assertTrue(combat.getAttackersOf(weak).isEmpty());
        assertEquals(1, combat.getAttackersOf(strong).size());
    }

    @Test
    public void spreadsDamageAcrossPeersAndKeepsAnEliminablePeerAlive() {
        Game game = gameWithPlayers(GameType.Commander, 4);
        Player ai = game.getPlayers().get(0);
        Player low = game.getPlayers().get(1);
        low.setLife(3, null);
        addCards("Grizzly Bears", 4, ai).forEach(card -> card.setSickness(false));

        Combat combat = declareAttackers(ai);

        assertEquals(1, combat.getAttackersOf(low).size());
        assertEquals(3, combat.getDefendingPlayers().stream().filter(player -> !combat.getAttackersOf(player).isEmpty()).count());
        assertEquals(4, combat.getAttackers().size());
    }

    @Test
    public void holdsBackWhenEitherAttackWouldEliminateAPeer() {
        Game game = gameWithPlayers(GameType.Commander, 3);
        Player ai = game.getPlayers().get(0);
        ai.getOpponents().forEach(opponent -> opponent.setLife(2, null));
        addCard("Grizzly Bears", ai).setSickness(false);

        assertTrue(declareAttackers(ai).getAttackers().isEmpty());
    }

    @Test
    public void stillDeclaresRequiredAttacks() {
        Game game = gameWithPlayers(GameType.Commander, 3);
        Player ai = game.getPlayers().get(0);
        ai.getOpponents().forEach(opponent -> opponent.setLife(2, null));
        Card juggernaut = addCard("Juggernaut", ai);
        juggernaut.setSickness(false);

        assertTrue(declareAttackers(ai).isAttacking(juggernaut));
    }

    @Test
    public void attacksForLethalWithOnlyOneOpponent() {
        Game game = gameWithPlayers(GameType.Commander, 2);
        Player ai = game.getPlayers().get(0);
        Player opponent = game.getPlayers().get(1);
        opponent.setLife(2, null);
        addCard("Grizzly Bears", ai).setSickness(false);

        assertEquals(1, declareAttackers(ai).getAttackersOf(opponent).size());
    }

    @Test
    public void otherMultiplayerFormatsStillAttackForLethal() {
        Game game = gameWithPlayers(GameType.Constructed, 3);
        Player ai = game.getPlayers().get(0);
        Player opponent = game.getPlayers().get(1);
        opponent.setLife(2, null);
        addCard("Grizzly Bears", ai).setSickness(false);

        assertEquals(1, declareAttackers(ai).getAttackersOf(opponent).size());
    }

    private static Game gameWithPlayers(GameType type, int count) {
        GameRules rules = new GameRules(GameType.Constructed);
        if (type == GameType.Commander) {
            rules.addAppliedVariant(type);
        }
        List<RegisteredPlayer> players = IntStream.range(0, count)
                .mapToObj(seat -> new RegisteredPlayer(new Deck()).setPlayer(new LobbyPlayerAi("Player " + seat, null)))
                .toList();
        Game game = new Match(rules, players, "Test").createGame();
        game.setAge(GameStage.Play);
        game.getPlayers().forEach(player -> player.setLife(40, null));
        return game;
    }

    private static Combat declareAttackers(Player ai) {
        ai.getGame().getPhaseHandler().devModeSet(PhaseType.COMBAT_DECLARE_ATTACKERS, ai);
        Combat combat = new Combat(ai);
        ai.getGame().getPhaseHandler().setCombat(combat);
        ai.getController().declareAttackers(ai, combat);
        assertTrue(CombatUtil.validateAttackers(combat));
        return combat;
    }
}
