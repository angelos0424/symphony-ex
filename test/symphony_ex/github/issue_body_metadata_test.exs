defmodule SymphonyEx.GitHub.IssueBodyMetadataTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.GitHub.IssueBodyMetadata

  test "parses service, paths, release, and conflict hints from mixed-case metadata lines" do
    body = """
    Service: API
    PATHS: lib/symphony_ex/orchestrator.ex, README.md
    Release: 2026.04
    """

    metadata = IssueBodyMetadata.parse(body)

    assert metadata.service == "api"
    assert metadata.paths == ["lib/symphony_ex/orchestrator.ex", "readme.md"]
    assert metadata.release == "2026.04"
    assert metadata.missing_required_fields == []

    assert metadata.conflict_hints == [
             "service:api",
             "path:lib/symphony_ex/orchestrator.ex",
             "path:readme.md",
             "release:2026.04"
           ]
  end

  test "marks missing required fields when service or paths metadata is absent" do
    assert IssueBodyMetadata.parse("Paths: lib/symphony_ex/orchestrator.ex").missing_required_fields ==
             [:service]

    assert IssueBodyMetadata.parse("Service: api").missing_required_fields == [:paths]
  end

  test "ignores empty metadata values and stray separators" do
    body = """
    Service: ,
    Paths: , lib/symphony_ex/orchestrator.ex ,, README.md
    """

    metadata = IssueBodyMetadata.parse(body)

    assert metadata.service == nil
    assert metadata.paths == ["lib/symphony_ex/orchestrator.ex", "readme.md"]
    assert metadata.missing_required_fields == [:service]
  end
end
