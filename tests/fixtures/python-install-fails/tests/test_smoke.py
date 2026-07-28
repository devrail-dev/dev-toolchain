def test_should_never_run():
    raise AssertionError("pytest ran despite a failed dependency install — AC 8 violated")
