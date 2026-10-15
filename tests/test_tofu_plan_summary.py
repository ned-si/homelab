"""scripts/ci/tofu_plan_summary.py: plan classification and what reaches the output."""
import tofu_plan_summary as s


def rc(address, *actions, secret=None):
    after = {"secret": secret} if secret else {}
    return {"address": address, "change": {"actions": list(actions), "after": after}}


def test_no_changes():
    plan = {"resource_changes": [rc("aws_s3_bucket.backups", "no-op"), rc("data.x.y", "read")]}
    assert s.classify(plan)[0] == "no-changes"


def test_update_is_changes():
    status, rows, _ = s.classify({"resource_changes": [rc("aws_iam_user_policy.backup", "update")]})
    assert status == "changes"
    assert rows == [("aws_iam_user_policy.backup", "update")]


def test_replace_and_delete_are_destructive():
    for actions in (("delete", "create"), ("create", "delete"), ("delete",), ("forget",)):
        status, rows, _ = s.classify({"resource_changes": [rc("aws_iam_access_key.backup", *actions)]})
        assert status == "destructive", actions
    assert s.classify({"resource_changes": [rc("a.b", "delete", "create")]})[1] == [("a.b", "replace")]


def test_drift_listed_but_not_a_change():
    plan = {"resource_drift": [rc("aws_s3_bucket_lifecycle_configuration.backups", "update")]}
    status, rows, drift = s.classify(plan)
    assert status == "no-changes"
    assert drift == [("aws_s3_bucket_lifecycle_configuration.backups", "drifted")]


def test_render_prints_no_values():
    plan = {"resource_changes": [rc("aws_iam_access_key.backup", "create", secret="TOPSECRETVALUE")]}
    out = s.render("bootstrap/aws-backup", *s.classify(plan))
    assert out.splitlines()[0] == "status=changes"
    assert "TOPSECRETVALUE" not in out
    assert "`aws_iam_access_key.backup`: create" in out
