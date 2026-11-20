import { useCallback } from "react";
import { toast } from "sonner";

import { ToastSeverity } from "@/types/toast";


/** The only entry point for toasts in features (sonner is imported only here and in components/ui/sonner.tsx). */
export function useToast() {
  const showAlert = useCallback((message: string, severity: ToastSeverity = ToastSeverity.INFO) => {
    toast[severity](message);
  }, []);
  return { showAlert };
}
