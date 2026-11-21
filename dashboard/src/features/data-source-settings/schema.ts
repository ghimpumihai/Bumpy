import { z } from "zod";

import { DataSourceMode } from "@/types/config";

const httpUrl = z.url({ protocol: /^https?$/ });

/**
 * A page served over HTTPS can't call a plain-http API: the browser blocks it as mixed content (and the
 * deployed CSP allows only `https:`), which would surface as "could not be reached" on every page.
 */
export function isBlockedMixedContent(apiBase: string, pageProtocol: string | undefined): boolean {
  return pageProtocol === "https:" && /^http:/i.test(apiBase);
}

/**
 * The API URL is only validated when it is used: in mock mode a half-typed URL must not block saving.
 * The field stays registered while hidden (no `shouldUnregister`), so the schema always sees a string.
 */
export const dataSourceFormSchema = z
  .object({
    mode: z.enum(Object.values(DataSourceMode)),
    apiBase: z.string().trim(),
  })
  .superRefine((value, ctx) => {
    if (value.mode === DataSourceMode.MOCK) return;
    if (value.apiBase === "") {
      if (value.mode === DataSourceMode.API) {
        ctx.addIssue({ code: "custom", path: ["apiBase"], message: "An API URL is required when the data source is the API." });
      }
      return;
    }
    if (!httpUrl.safeParse(value.apiBase).success) {
      ctx.addIssue({
        code: "custom",
        path: ["apiBase"],
        message: "Enter a full http(s) URL, e.g. https://read-api.example.com",
      });
    } else if (isBlockedMixedContent(value.apiBase, globalThis.location?.protocol)) {
      ctx.addIssue({
        code: "custom",
        path: ["apiBase"],
        message: "This site is served over HTTPS, so the browser blocks a plain http:// API. Use an https:// URL.",
      });
    }
  })
  .transform((value) => ({ mode: value.mode, apiBase: value.mode === DataSourceMode.MOCK ? "" : value.apiBase }));

export type DataSourceFormInput = z.input<typeof dataSourceFormSchema>;
export type DataSourceFormValues = z.output<typeof dataSourceFormSchema>;
