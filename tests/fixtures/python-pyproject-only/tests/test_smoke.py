def test_dependency_is_importable():
    import inflection

    assert inflection.underscore("HelloWorld") == "hello_world"
