import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

import { ModelFitCard } from "./components/model-fit-card";
import { METHOD_SECTIONS, PIPELINE_STEPS } from "./utils/content";

export function MethodView() {
  return (
    <div className="vertical gap-6">
      <ol className="grid gap-3 md:grid-cols-5" aria-label="Pipeline">
        {PIPELINE_STEPS.map((step, index) => (
          <li key={step.title} className="vertical gap-1 rounded-lg border bg-card p-4">
            <span className="text-xs font-medium text-accent">Step {index + 1}</span>
            <span className="font-semibold">{step.title}</span>
            <span className="text-sm text-muted-foreground">{step.text}</span>
          </li>
        ))}
      </ol>
      <div className="grid gap-6 lg:grid-cols-2">
        {METHOD_SECTIONS.map((section) => (
          <Card key={section.title}>
            <CardHeader>
              <CardTitle>{section.title}</CardTitle>
            </CardHeader>
            <CardContent>
              <ul className="vertical list-disc gap-2 pl-5 text-sm text-muted-foreground marker:text-accent">
                {section.points.map((point) => (
                  <li key={point}>{point}</li>
                ))}
              </ul>
            </CardContent>
          </Card>
        ))}
        <ModelFitCard />
      </div>
    </div>
  );
}
