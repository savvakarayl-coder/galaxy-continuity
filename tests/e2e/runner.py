#!/usr/bin/env python3
"""
Galaxy Continuity — Master E2E Test Runner
Discovers, executes, and summarizes all 4 test tiers with zero external dependencies.

Usage:
  python3 tests/e2e/runner.py                 # Run all tiers (1-4)
  python3 tests/e2e/runner.py --tier 1        # Run Tier 1 (Representative features)
  python3 tests/e2e/runner.py --tier 2        # Run Tier 2 (Boundary & edge cases)
  python3 tests/e2e/runner.py --tier 3        # Run Tier 3 (Cross-feature pairwise)
  python3 tests/e2e/runner.py --tier 4        # Run Tier 4 (Workload scenarios)
  python3 tests/e2e/runner.py -v              # Verbose test runner
  python3 tests/e2e/runner.py --filter TestUniversalClipboard
"""

import argparse
import os
import sys
import time
import unittest
from typing import Dict, List, Optional

# Ensure project root is in sys.path
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

TIER_MODULE_MAP = {
    1: "tests.e2e.test_tier1_features",
    2: "tests.e2e.test_tier2_boundary",
    3: "tests.e2e.test_tier3_pairwise",
    4: "tests.e2e.test_tier4_workload",
}

TIER_DESCRIPTIONS = {
    1: "Tier 1: Category-Partition Equivalence Classes (Representative Happy Paths)",
    2: "Tier 2: Boundary Value Analysis & Negative/Adversarial Edge Cases",
    3: "Tier 3: Pairwise & Cross-Feature Interaction Integration Tests",
    4: "Tier 4: End-to-End Real-World User Workload Scenarios",
}


class TierResultTracker:
    def __init__(self):
        self.tier_stats: Dict[int, Dict[str, Any]] = {}
        self.total_tests = 0
        self.total_passed = 0
        self.total_failed = 0
        self.total_errors = 0
        self.total_skipped = 0
        self.start_time = 0.0
        self.end_time = 0.0

    def record_tier(self, tier: int, count: int, passed: int, failed: int, errors: int, skipped: int, duration: float):
        self.tier_stats[tier] = {
            "count": count,
            "passed": passed,
            "failed": failed,
            "errors": errors,
            "skipped": skipped,
            "duration": duration,
        }
        self.total_tests += count
        self.total_passed += passed
        self.total_failed += failed
        self.total_errors += errors
        self.total_skipped += skipped


def run_tier(tier: int, verbosity: int = 1, pattern_filter: Optional[str] = None) -> unittest.TestResult:
    """Load and execute test suite for a specific tier."""
    module_name = TIER_MODULE_MAP.get(tier)
    if not module_name:
        raise ValueError(f"Unknown tier: {tier}")

    loader = unittest.TestLoader()
    try:
        suite = loader.loadTestsFromName(module_name)
    except Exception as e:
        print(f"\n❌ Failed to load test module {module_name}: {e}")
        result = unittest.TestResult()
        result.errors.append((str(module_name), str(e)))
        return result

    if pattern_filter:
        filtered_suite = unittest.TestSuite()
        def _filter_tests(test_item):
            if isinstance(test_item, unittest.TestSuite):
                for sub in test_item:
                    _filter_tests(sub)
            elif isinstance(test_item, unittest.TestCase):
                if pattern_filter in test_item.id():
                    filtered_suite.addTest(test_item)
        _filter_tests(suite)
        suite = filtered_suite

    runner = unittest.TextTestRunner(verbosity=verbosity)
    return runner.run(suite)


def print_banner(text: str):
    print("\n" + "=" * 78)
    print(f" {text}")
    print("=" * 78)


def print_summary_table(tracker: TierResultTracker):
    print_banner("GALAXY CONTINUITY — E2E TEST EXECUTION SUMMARY")
    print(f"{'Tier':<8} {'Description':<42} {'Count':<7} {'Pass':<6} {'Fail':<6} {'Time':<8}")
    print("-" * 78)

    for tier in sorted(tracker.tier_stats.keys()):
        stat = tracker.tier_stats[tier]
        desc = TIER_DESCRIPTIONS.get(tier, f"Tier {tier}")
        if len(desc) > 40:
            desc = desc[:37] + "..."
        count = stat["count"]
        passed = stat["passed"]
        failed = stat["failed"] + stat["errors"]
        duration = f"{stat['duration']:.2f}s"
        status_color = "✅" if failed == 0 else "❌"
        print(f"{tier:<8} {desc:<42} {count:<7} {passed:<6} {failed:<6} {duration:<8} {status_color}")

    print("-" * 78)
    total_duration = f"{tracker.end_time - tracker.start_time:.2f}s"
    print(f"{'TOTAL':<8} {'All Tiers Combined':<42} {tracker.total_tests:<7} {tracker.total_passed:<6} {tracker.total_failed + tracker.total_errors:<6} {total_duration:<8}")
    print("=" * 78)

    if tracker.total_failed == 0 and tracker.total_errors == 0:
        print("🎉 ALL TESTS PASSED! Continuous integration ready.")
    else:
        print(f"❌ {tracker.total_failed + tracker.total_errors} TEST(S) FAILED. Inspect logs above for details.")


def main():
    parser = argparse.ArgumentParser(description="Galaxy Continuity Master E2E Test Runner")
    parser.add_argument("--tier", type=int, choices=[1, 2, 3, 4], help="Run a specific tier only (1, 2, 3, or 4)")
    parser.add_argument("--all", action="store_true", help="Run all tiers (default)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose test execution output")
    parser.add_argument("-q", "--quiet", action="store_true", help="Minimal output")
    parser.add_argument("--filter", type=str, help="Filter tests by name/substring")
    args = parser.parse_args()

    verbosity = 2 if args.verbose else (0 if args.quiet else 1)
    tiers_to_run = [args.tier] if args.tier else [1, 2, 3, 4]

    tracker = TierResultTracker()
    tracker.start_time = time.time()

    print_banner("GALAXY CONTINUITY E2E TEST SUITE")
    print(f"Execution Target: Port 8765 / In-Process Mock Harness")
    print(f"Running Tiers: {tiers_to_run}")
    if args.filter:
        print(f"Active Filter: {args.filter}")

    all_passed = True

    for tier in tiers_to_run:
        tier_title = TIER_DESCRIPTIONS.get(tier, f"Tier {tier}")
        print(f"\n▶ Running [{tier_title}]...")
        t_start = time.time()
        result = run_tier(tier, verbosity=verbosity, pattern_filter=args.filter)
        t_duration = time.time() - t_start

        count = result.testsRun
        errors = len(result.errors)
        failures = len(result.failures)
        skipped = len(result.skipped)
        passed = count - errors - failures - skipped

        tracker.record_tier(tier, count, passed, failures, errors, skipped, t_duration)

        if failures > 0 or errors > 0:
            all_passed = False

    tracker.end_time = time.time()
    print_summary_table(tracker)

    sys.exit(0 if all_passed else 1)


if __name__ == "__main__":
    main()
