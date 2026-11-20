import { zodResolver } from "@hookform/resolvers/zod";
import { Database, FlaskConical, RotateCcw } from "lucide-react";
import { useState } from "react";
import { Controller, useForm, useWatch } from "react-hook-form";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { applyDataSourceOverride, readDataSourceOverride } from "@/config/runtime-config";
import { DataSourceMode, type DataSource } from "@/types/config";

import { dataSourceFormSchema, type DataSourceFormInput, type DataSourceFormValues } from "./schema";

const MODE_LABELS: Record<DataSourceMode, string> = {
  auto: "Automatic (API from config.json, else mock data)",
  mock: "Mock data (in the browser)",
  api: "Read API at this URL",
};

interface DataSourceSettingsProps {
  dataSource: DataSource;
}

/** Shows where data comes from and lets a teammate point this browser at another read API. */
export function DataSourceSettings({ dataSource }: DataSourceSettingsProps) {
  const [open, setOpen] = useState(false);
  const saved = readDataSourceOverride();
  const form = useForm<DataSourceFormInput, unknown, DataSourceFormValues>({
    resolver: zodResolver(dataSourceFormSchema),
    defaultValues: { mode: saved?.mode ?? DataSourceMode.AUTO, apiBase: saved?.apiBase ?? "" },
  });
  const mode = useWatch({ control: form.control, name: "mode" });

  // The data source is resolved once at startup; reloading guarantees no mixed caches.
  const apply = (values: DataSourceFormValues | null) => applyDataSourceOverride(values);

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="sm" aria-label={`${dataSource.kind === "mock" ? "Mock data" : "Read API"}: data source settings`}>
          {dataSource.kind === "mock" ? (
            <Badge variant="highlight">
              <FlaskConical aria-hidden="true" />
              Mock data
            </Badge>
          ) : (
            <Badge variant="success">
              <Database aria-hidden="true" />
              Read API
            </Badge>
          )}
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Data source</DialogTitle>
          <DialogDescription>
            {dataSource.kind === "mock"
              ? "Showing generated mock sessions in the same format as the real pipeline."
              : `Reading from ${dataSource.apiBase}.`}{" "}
            Changes apply to this browser only.
          </DialogDescription>
        </DialogHeader>
        <form id="data-source-form" className="vertical gap-4" onSubmit={form.handleSubmit(apply)} noValidate>
          <div className="vertical gap-2">
            <Label htmlFor="data-source-mode">Source</Label>
            <Controller
              control={form.control}
              name="mode"
              render={({ field }) => (
                <Select value={field.value} onValueChange={field.onChange}>
                  <SelectTrigger id="data-source-mode" className="w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {Object.values(DataSourceMode).map((value) => (
                      <SelectItem key={value} value={value}>
                        {MODE_LABELS[value]}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            />
          </div>
          <div className="vertical gap-2" hidden={mode === DataSourceMode.MOCK}>
              <Label htmlFor="data-source-url">API base URL {mode === DataSourceMode.AUTO && "(optional override)"}</Label>
              <Input
                id="data-source-url"
                type="url"
                placeholder="http://localhost:8000"
                aria-invalid={Boolean(form.formState.errors.apiBase)}
                aria-describedby="data-source-url-error"
                {...form.register("apiBase")}
              />
              <p id="data-source-url-error" className="text-xs text-destructive" aria-live="polite">
                {form.formState.errors.apiBase?.message}
              </p>
          </div>
        </form>
        <DialogFooter className="gap-2 sm:justify-between">
          <Button type="button" variant="ghost" leftIcon={<RotateCcw />} onClick={() => apply(null)}>
            Reset to default
          </Button>
          <Button type="submit" form="data-source-form">
            Save and reload
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
