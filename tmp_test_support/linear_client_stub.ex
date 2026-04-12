defmodule SymphonyEx.Test.LinearClientStub do
  @moduledoc false

  def request(request) do
    send(self(), {:linear_request, request})

    {:ok,
     %Req.Response{
       status: 200,
       body: %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-1",
                 "identifier" => "SYM-1",
                 "title" => "Phase 2 foundation",
                 "description" => "Ship adapter layer",
                 "url" => "https://linear.app/example/issue/SYM-1",
                 "priority" => 2,
                 "labels" => %{"nodes" => [%{"name" => "backend"}]},
                 "parent" => %{"id" => "parent-1"},
                 "children" => %{"nodes" => [%{"id" => "child-1"}]},
                 "state" => %{"id" => "state-1", "name" => "Todo", "type" => "unstarted"}
               }
             ]
           }
         }
       }
     }}
  end
end
