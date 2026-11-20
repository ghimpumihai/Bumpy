import { useCallback } from "react";
import { toast } from "sonner";

export const ToastSeverity = {
  SUCCESS: "success",
  WARNING: "warning",
  ERROR: "error",
  INFO: "info",
  LOADING: "loading",
} as const;
export type ToastSeverity = (typeof ToastSeverity)[keyof typeof ToastSeverity];

/** The only entry point for toasts in features (sonner is imported only here and in components/ui/sonner.tsx). */
export function useToast() {
  const showAlert = useCallback((message: string, severity: ToastSeverity = ToastSeverity.INFO) => {
    toast[severity](message);
  }, []);
  return { showAlert };
}
