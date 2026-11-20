import type { QueryClient } from "@tanstack/react-query";

import type { DataSource } from "@/types/config";

export interface RouterContext {
  queryClient: QueryClient;
  dataSource: DataSource;
}
