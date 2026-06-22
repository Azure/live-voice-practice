/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { tokens } from '@fluentui/react-components'

/**
 * Shared Fluent-token palette for every chart in the admin dashboards. Keeping
 * this in one place means all charts stay visually consistent and theme-aware.
 */
export const chartColors = {
  primary: tokens.colorBrandForeground1,
  secondary: tokens.colorPaletteGreenForeground1,
  accent: tokens.colorPaletteBerryForeground1,
  success: tokens.colorPaletteGreenForeground1,
  warning: tokens.colorPaletteYellowForeground1,
  danger: tokens.colorPaletteRedForeground1,
  axis: tokens.colorNeutralForeground3,
  grid: tokens.colorNeutralStroke2,
}

export function scoreColor(value: number | null | undefined): string {
  if (value === null || value === undefined) return chartColors.axis
  if (value >= 70) return chartColors.success
  if (value >= 50) return chartColors.warning
  return chartColors.danger
}

export function inverseScoreColor(value: number | null | undefined): string {
  if (value === null || value === undefined) return chartColors.axis
  if (value <= 20) return chartColors.success
  if (value <= 50) return chartColors.warning
  return chartColors.danger
}
