import { css } from '@emotion/css';

import { type PanelProps } from '@grafana/data';
import { LegendDisplayMode, SortOrder, TooltipDisplayMode, VizOrientation } from '@grafana/schema';
import { useStyles2 } from '@grafana/ui';

import { PieChartPanel } from '../piechart/PieChartPanel';
import {
  type Options as PieChartOptions,
  PieChartLabels,
  PieChartLegendValues,
  PieChartType,
} from '../piechart/panelcfg.gen';

import { TablePanel } from './TablePanel';
import { type Options as TableOptions } from './panelcfg.gen';

// The frame also carries a string column and an enum column, which would reduce to
// meaningless slices. Restricting the reducer to the numeric fields keeps the slice
// set stable no matter what non-numeric columns the query returns.
const NUMERIC_FIELDS = '/^(Value|Min|Max)$/';

const PIE_WIDTH_FRACTION = 0.4;

const noopOptionsChange = () => {};

const pieOptions: PieChartOptions = {
  // `range` rather than a point reducer: the series walks freely through zero, and a
  // negative slice renders as a broken arc. max-min is always non-negative.
  reduceOptions: { values: false, calcs: ['range'], fields: NUMERIC_FIELDS },
  pieType: PieChartType.Donut,
  displayLabels: [PieChartLabels.Name, PieChartLabels.Percent],
  legend: {
    displayMode: LegendDisplayMode.List,
    placement: 'right',
    showLegend: true,
    calcs: [],
    values: [PieChartLegendValues.Percent],
  },
  tooltip: { mode: TooltipDisplayMode.Single, sort: SortOrder.None },
  orientation: VizOrientation.Auto,
  sort: SortOrder.Descending,
};

export function TablePieView(props: PanelProps<TableOptions>) {
  const styles = useStyles2(getStyles);
  // Both children size themselves from the width/height props rather than from CSS, so
  // the split has to be computed and passed down explicitly.
  const pieWidth = Math.round(props.width * PIE_WIDTH_FRACTION);
  const tableWidth = props.width - pieWidth;

  return (
    <div className={styles.split} style={{ width: props.width, height: props.height }}>
      <TablePanel {...props} width={tableWidth} />
      {/* The pie renders from fixed options, so there is nothing to persist back. */}
      <PieChartPanel {...props} options={pieOptions} width={pieWidth} onOptionsChange={noopOptionsChange} />
    </div>
  );
}

const getStyles = () => ({
  split: css({
    display: 'flex',
    flexDirection: 'row',
  }),
});
