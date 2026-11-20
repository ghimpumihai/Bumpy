export const ToastSeverity = {
  SUCCESS: "success",
  WARNING: "warning",
  ERROR: "error",
  INFO: "info",
  LOADING: "loading",
} as const;
export type ToastSeverity = (typeof ToastSeverity)[keyof typeof ToastSeverity];
