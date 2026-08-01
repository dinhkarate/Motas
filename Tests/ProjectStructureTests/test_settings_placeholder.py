from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SettingsPlaceholderTests(unittest.TestCase):
    def test_settings_scene_is_reachable_from_menu_bar(self) -> None:
        app_source = (ROOT / "Sources/MotasApp/MotasApp.swift").read_text()
        popover_source = (ROOT / "Sources/MotasApp/StatusPopoverView.swift").read_text()

        self.assertIn("Settings {", app_source)
        self.assertIn("SettingsView(model: model)", app_source)
        self.assertIn("SettingsLink {", popover_source)

    def test_required_placeholder_sections_are_present(self) -> None:
        settings_source = (ROOT / "Sources/MotasApp/SettingsView.swift").read_text()

        for section in ("Connectors", "Refresh", "Appearance"):
            self.assertIn(f'Section("{section}")', settings_source)


if __name__ == "__main__":
    unittest.main()
