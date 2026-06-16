import Foundation

/// Pure diff engine: previous vs next state of one fixture → events to fire.
/// A Swift port of the backend `diff.ts` (`diffMatch`). Event ids are
/// deterministic so the same transition recomputes the same id and
/// `EventRouter.seenEventIds` dedupes.
///
/// BASELINE GUARD: the *caller* (LiveStore) seeds the first observation of a
/// fixture as the baseline and does NOT diff it, so pre-launch goals are never
/// replayed. This function additionally guards `prev == nil && FINISHED`, which
/// mirrors the backend (a deleted/never-written state for an over match).
enum MatchDiff {
    static func diff(prev: Fixture?, next: Fixture) -> [MatchEvent] {
        // No previous state for an already-over match: nothing to replay.
        if prev == nil, next.status == "FINISHED" { return [] }

        var events: [MatchEvent] = []

        func make(
            _ type: MatchEventType,
            idSuffix: String? = nil,
            teamId: Int? = nil,
            player: String? = nil,
            minute: Int? = nil,
            extra: Int? = nil,
            penHome: Int? = nil,
            penAway: Int? = nil,
            scored: Bool? = nil
        ) -> MatchEvent {
            let id = "\(next.fixtureId):\(type.rawValue)" + (idSuffix.map { ":\($0)" } ?? "")
            return MatchEvent(
                eventId: id,
                type: type,
                fixtureId: next.fixtureId,
                leagueId: next.leagueId,
                teamId: teamId,
                player: player,
                minute: minute,
                extra: extra,
                homeTeamId: next.home.id,
                awayTeamId: next.away.id,
                homeName: next.home.name,
                awayName: next.away.name,
                homeGoals: next.home.goals,
                awayGoals: next.away.goals,
                penHome: penHome,
                penAway: penAway,
                scored: scored
            )
        }

        // Status transitions.
        let was = prev?.status ?? "SCHEDULED"
        let wasRaw = prev?.rawStatus ?? "NS"
        let nextRaw = next.rawStatus ?? ""

        if was == "SCHEDULED", next.status == "LIVE" {
            events.append(make(.kickoff))
        }
        if nextRaw == "HT", wasRaw != "HT" {
            events.append(make(.halfTime))
        }

        // Shootout tally, attached to the score-bearing end-of-match events.
        let pensHome = next.shootout?.home
        let pensAway = next.shootout?.away

        if next.status == "FINISHED", was != "FINISHED" {
            events.append(make(.fullTime, penHome: pensHome, penAway: pensAway))
        }
        // ET begins once; don't re-fire across the BT break between ET halves.
        if nextRaw == "ET", wasRaw != "ET", wasRaw != "BT" {
            events.append(make(.extraTime))
        }
        if nextRaw == "P", wasRaw != "P" {
            events.append(make(.penaltyShootout, penHome: pensHome, penAway: pensAway))
        }

        // Penalty shootout — one event per new kick; running tally from the
        // ordered kick list so ids stay deterministic and pills show live pens.
        let prevKicks = prev?.shootout?.kicks.count ?? 0
        let kicks = next.shootout?.kicks ?? []
        var penHome = 0
        var penAway = 0
        for (i, kick) in kicks.enumerated() {
            if kick.scored {
                if kick.teamId == next.home.id { penHome += 1 } else { penAway += 1 }
            }
            if i < prevKicks { continue } // already published
            events.append(make(
                .penaltyKick,
                idSuffix: String(i + 1),
                teamId: kick.teamId,
                player: kick.player,
                penHome: penHome,
                penAway: penAway,
                scored: kick.scored
            ))
        }

        // Goals — one event per increment; decrements are VAR cancellations.
        for side in [Side.home, Side.away] {
            let team = side == .home ? next.home : next.away
            let before = side == .home ? (prev?.home.goals ?? 0) : (prev?.away.goals ?? 0)
            let after = team.goals
            if after > before {
                var g = before + 1
                while g <= after {
                    let goalEv = team.goalEvents.indices.contains(g - 1) ? team.goalEvents[g - 1] : nil
                    events.append(make(
                        .goal,
                        idSuffix: "\(team.id):\(g)",
                        teamId: team.id,
                        player: goalEv?.player ?? team.name,
                        minute: goalEv?.minute ?? next.minute,
                        extra: goalEv?.extra
                    ))
                    g += 1
                }
            }
            if before > after {
                var g = before
                while g > after {
                    events.append(make(
                        .goalCancelled,
                        idSuffix: "\(team.id):\(g)",
                        teamId: team.id,
                        minute: next.minute
                    ))
                    g -= 1
                }
            }
        }

        // Cards — count-based; one event per new card.
        for side in [Side.home, Side.away] {
            let team = side == .home ? next.home : next.away
            let prevTeam = side == .home ? prev?.home : prev?.away
            let cardKinds: [(count: Int, events: [MatchTimelineEvent], before: Int, type: MatchEventType)] = [
                (team.yellowCards, team.yellowCardEvents, prevTeam?.yellowCards ?? 0, .yellowCard),
                (team.redCards, team.redCardEvents, prevTeam?.redCards ?? 0, .redCard),
            ]
            for kind in cardKinds {
                var c = kind.before + 1
                while c <= kind.count {
                    let cardEv = kind.events.indices.contains(c - 1) ? kind.events[c - 1] : nil
                    events.append(make(
                        kind.type,
                        idSuffix: "\(team.id):\(c)",
                        teamId: team.id,
                        player: cardEv?.player,
                        minute: cardEv?.minute ?? next.minute,
                        extra: cardEv?.extra
                    ))
                    c += 1
                }
            }
        }

        return events
    }

    private enum Side { case home, away }
}
