def test_dependency_is_importable():
    from first import first

    assert first([0, False, None, 3, 4]) == 3
