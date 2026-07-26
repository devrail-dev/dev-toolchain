def test_override_was_used_not_autodetected_requirements_txt():
    from first import first

    assert first([0, None, 5]) == 5
