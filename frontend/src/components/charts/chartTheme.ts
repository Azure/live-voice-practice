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
  axis: tokens.colorNeutralForeground3,
  grid: tokens.colorNeutralStroke2,
}
