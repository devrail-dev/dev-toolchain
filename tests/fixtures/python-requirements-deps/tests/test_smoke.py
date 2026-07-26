def test_dependency_is_importable():
    import humanize

    assert humanize.naturalsize(1000000) == "1.0 MB"
