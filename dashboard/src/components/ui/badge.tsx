import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"
import { cn } from "@/lib/utils"
import { Slot } from "radix-ui"

// Flat status text with a small dot, no pill.
const badgeVariants = cva(
  "inline-flex w-fit shrink-0 items-center gap-1.5 text-xs font-medium whitespace-nowrap before:size-1.5 before:shrink-0 before:rounded-full before:bg-current [&>svg]:hidden",
  {
    variants: {
      variant: {
        default: "text-foreground",
        secondary: "text-muted-foreground",
        destructive: "text-destructive",
        outline: "text-muted-foreground",
        ghost: "text-muted-foreground",
        link: "text-foreground underline-offset-4 hover:underline",
        success: "text-success",
        warning: "text-warning",
        info: "text-info",
        highlight: "text-highlight-foreground",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  }
)

function Badge({
  className,
  variant = "default",
  asChild = false,
  ...props
}: React.ComponentProps<"span"> &
  VariantProps<typeof badgeVariants> & { asChild?: boolean }) {
  const Comp = asChild ? Slot.Root : "span"

  return (
    <Comp
      data-slot="badge"
      data-variant={variant}
      className={cn(badgeVariants({ variant }), className)}
      {...props}
    />
  )
}

export { Badge, badgeVariants }
