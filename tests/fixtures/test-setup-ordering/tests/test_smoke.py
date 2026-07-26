import os


def test_setup_ran_before_tests():
    assert os.path.exists("setup-ran.marker")
