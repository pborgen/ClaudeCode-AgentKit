import pytest

from pr_fixer.state import AttemptStore, LockError, attempt_key, lockfile


def test_attempt_key_includes_sha():
    k1 = attempt_key("o/r", 5, "aaa")
    k2 = attempt_key("o/r", 5, "bbb")
    assert k1 != k2
    assert "5" in k1 and "aaa" in k1


def test_attempt_store_counts_and_exhausts(tmp_path):
    store = AttemptStore(tmp_path / "attempts.json")
    key = attempt_key("o/r", 1, "sha")
    assert store.attempts(key) == 0
    assert not store.exhausted(key, 3)
    assert store.record_attempt(key) == 1
    assert store.record_attempt(key) == 2
    assert store.record_attempt(key) == 3
    assert store.exhausted(key, 3)


def test_attempt_store_persists(tmp_path):
    path = tmp_path / "attempts.json"
    AttemptStore(path).record_attempt("k")
    assert AttemptStore(path).attempts("k") == 1


def test_lock_excludes_second_holder(tmp_path):
    lock = tmp_path / "x.lock"
    with lockfile(lock):
        with pytest.raises(LockError):
            with lockfile(lock):
                pass
    # released after exit -> can reacquire
    with lockfile(lock):
        pass


def test_stale_lock_is_reclaimed(tmp_path):
    lock = tmp_path / "x.lock"
    lock.write_text("999999")  # almost certainly not a live PID
    with lockfile(lock):
        pass  # should acquire by reclaiming the stale lock
