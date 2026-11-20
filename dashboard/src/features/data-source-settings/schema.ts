import { z } from "zod";

import { DataSourceMode } from "@/types/config";

export const dataSourceFormSchema = z
  .object({
    mode: z.enum(Object.values(DataSourceMode)),
    apiBase: z.union([z.url({ message: "Enter a full URL, e.g. https://abc123.execute-api.eu-west-1.amazonaws.com" }), z.literal("")]),
  })
  .refine((value) => value.mode !== DataSourceMode.API || value.apiBase !== "", {
    path: ["apiBase"],
    message: "An API URL is required when the data source is the API.",
  });

export type DataSourceFormValues = z.infer<typeof dataSourceFormSchema>;
