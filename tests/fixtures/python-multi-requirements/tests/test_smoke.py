def test_requirements_txt_wins_over_requirements_dev_txt():
    import inflection

    assert inflection.underscore("HelloWorld") == "hello_world"
