#!/usr/bin/env python3
"""Testy dopasowania kart terminali. Uruchom: python3 test_alerts.py"""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import alerts


class TitleMatch(unittest.TestCase):
    def test_exact_with_prefix(self):
        self.assertTrue(alerts.title_matches("OC | Lekka aplikacja notatek", "Lekka aplikacja notatek"))

    def test_truncated_window_title(self):
        self.assertTrue(alerts.title_matches("OC | Automatyczne tutoriale video z Eleven…",
                                             "Automatyczne tutoriale video z ElevenLabs"))

    def test_short_prefix_does_not_match(self):
        self.assertFalse(alerts.title_matches("OC | Test", "Testowanie bannera"))

    def test_different_title(self):
        self.assertFalse(alerts.title_matches("OC | Raycast z OmniRoute", "Aktualizacje na GitHubie"))

    def test_empty(self):
        self.assertFalse(alerts.title_matches("", "x"))
        self.assertFalse(alerts.title_matches("OC | x", ""))


class Finders(unittest.TestCase):
    PANES = [
        {"pane_id": "w1:p1", "terminal_title_stripped": "OC | Inne zadanie",
         "agent_session": {"value": "ses_abc"}},
        {"pane_id": "w2:p1", "terminal_title_stripped": "OC | Naprawa formularza kontaktowego"},
    ]

    def test_herdr_by_session_id_wins(self):
        self.assertEqual(alerts.find_herdr(self.PANES, "ses_abc", "Naprawa formularza kontaktowego")["pane_id"], "w1:p1")

    def test_herdr_by_title(self):
        self.assertEqual(alerts.find_herdr(self.PANES, "ses_zzz", "Naprawa formularza kontaktowego")["pane_id"], "w2:p1")

    def test_herdr_none(self):
        self.assertIsNone(alerts.find_herdr(self.PANES, "ses_zzz", "Coś zupełnie innego"))

    def test_orca_by_title(self):
        terms = [{"handle": "term_1", "title": "✳ claude"}, {"handle": "term_2", "title": "OC | Aktualizacje na GitHubie"}]
        self.assertEqual(alerts.find_orca(terms, "Aktualizacje na GitHubie")["handle"], "term_2")


class Spool(unittest.TestCase):
    def test_load_sorted_and_remove(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(alerts, "SPOOL", Path(d)):
            for sid, t in (("a", "2026-10-17T08:00:00"), ("b", "2026-10-17T09:00:00")):
                (Path(d) / f"{sid}.json").write_text(json.dumps({"sessionID": sid, "time": t}))
            (Path(d) / "zly.json").write_text("{nie json")
            items = alerts.load_alerts()
            self.assertEqual([i["sessionID"] for i in items], ["b", "a"])
            alerts.remove_alert(items[0])
            self.assertEqual([i["sessionID"] for i in alerts.load_alerts()], ["a"])


if __name__ == "__main__":
    unittest.main()
