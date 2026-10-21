import unittest
from run_benchmark import cpu_seconds, phase_rows, summarize


class BenchmarkMetricTests(unittest.TestCase):
    def test_cpu_time_uses_cumulative_seconds_not_percent(self):
        self.assertAlmostEqual(cpu_seconds('833:13.07'), 49993.07)
        self.assertAlmostEqual(cpu_seconds('1:02:03.04'), 3723.04)
        self.assertAlmostEqual(cpu_seconds('0:00.12'), 0.12)
        with self.assertRaises(ValueError):
            cpu_seconds('unavailable')

    def test_sampling_boundary_excludes_measurement_and_readback_overlap(self):
        rows = [dict(unix=0.99, endUnix=1.01), dict(unix=1.2, endUnix=1.4),
                dict(unix=1.8, endUnix=2.01), dict(unix=2.1, endUnix=2.2)]
        self.assertEqual(phase_rows(rows, dict(startUnix=1, endUnix=2)), [rows[1]])

    def test_cpu_summary_uses_delta_and_preserves_full_gpu_scope(self):
        rows = [dict(unix=t, endUnix=t + 0.05,
            processes={'benchmark': dict(pid=3, cpuSeconds=cpu, rssMiB=20 + t)},
            gpu={'statistics': {'Device Utilization %': 30 + t}})
            for t, cpu in [(1, 100), (1.5, 100.2), (2, 100.5)]]
        result = dict(phase='1-pull30', mode='pull30', startUnix=0.9, endUnix=2.1)
        summary = summarize(rows, [result])[0]
        self.assertEqual(summary['processes']['benchmark']['cpuPercentOneCore'], 50)
        self.assertEqual(summary['processes']['benchmark']['peakSampledRSSMiB'], 22)
        self.assertEqual(summary['wholeGPUPercent']['mean'], 31.5)
        with self.assertRaisesRegex(RuntimeError, 'Insufficient'):
            summarize(rows[:2], [result])
        rows[-1]['processes']['benchmark']['pid'] = 4
        with self.assertRaisesRegex(RuntimeError, 'process changed'):
            summarize(rows, [result])


if __name__ == '__main__':
    unittest.main()
