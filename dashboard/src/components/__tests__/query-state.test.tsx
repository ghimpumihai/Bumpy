import { render, screen } from "@testing-library/react";
import { AxiosError } from "axios";
import { describe, expect, it } from "vitest";

import { QueryState } from "@/components/query-state";

const error = new AxiosError("Network Error");

describe("QueryState", () => {
  it("shows the error instead of content when nothing has loaded", () => {
    render(
      <QueryState isPending={false} error={error}>
        <p>content</p>
      </QueryState>,
    );
    expect(screen.getByRole("alert")).toHaveTextContent("could not be reached");
    expect(screen.queryByText("content")).toBeNull();
  });

  it("keeps loaded content when a background refresh fails", () => {
    render(
      <QueryState isPending={false} error={error} hasData>
        <p>content</p>
      </QueryState>,
    );
    expect(screen.getByText("content")).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("showing the last data");
    expect(screen.queryByRole("alert")).toBeNull();
  });
});
