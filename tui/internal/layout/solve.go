package layout

import "sort"

// Solve decides how many cells each column gets out of avail, in three
// phases:
//
//  1. Start every column at its Min, plus one gutter cell between each pair
//     of live neighbours.
//  2. While that sum exceeds avail, drop the lowest-Priority non-Sticky
//     column (ties break toward the highest index, so the order is
//     deterministic). If only Sticky columns remain and they still do not
//     fit, stop: their Min is returned as-is, never squeezed smaller — the
//     caller's own max-width backstop is what clips that case, not this
//     function pretending it solved something it did not.
//  3. Distribute whatever is left over avail's remaining cells across the
//     live columns with Flex > 0, weighted by Flex, using largest-remainder
//     rounding so the total is exact and stable across resizes (a column
//     doesn't gain or lose a cell just because a neighbour's rounding
//     tipped the other way on an adjacent width).
//
// The result has one entry per input column, in the same order; -1 marks a
// column Solve dropped.
func Solve(cols []Column, avail int) []int {
	n := len(cols)
	widths := make([]int, n)
	live := make([]bool, n)
	for i, c := range cols {
		live[i] = true
		widths[i] = c.Min
	}

	total := func() int {
		sum, count := 0, 0
		for i, l := range live {
			if !l {
				continue
			}
			sum += widths[i]
			count++
		}
		if count > 1 {
			sum += count - 1 // one gutter cell between each pair of live neighbours
		}
		return sum
	}

	for total() > avail {
		drop := -1
		for i, c := range cols {
			if !live[i] || c.Sticky {
				continue
			}
			if drop == -1 {
				drop = i
				continue
			}
			// Lowest priority goes first; a tie breaks toward the higher
			// index so the order is deterministic regardless of slice order.
			if c.Priority < cols[drop].Priority ||
				(c.Priority == cols[drop].Priority && i > drop) {
				drop = i
			}
		}
		if drop == -1 {
			break // nothing left that Solve is allowed to drop
		}
		live[drop] = false
		widths[drop] = -1
	}

	remaining := avail - total()
	if remaining <= 0 {
		return widths
	}

	totalFlex := 0
	for i, l := range live {
		if l && cols[i].Flex > 0 {
			totalFlex += cols[i].Flex
		}
	}
	if totalFlex == 0 {
		return widths
	}

	type share struct {
		idx  int
		frac float64
	}
	shares := make([]share, 0, n)
	distributed := 0
	for i, l := range live {
		if !l || cols[i].Flex <= 0 {
			continue
		}
		exact := float64(remaining) * float64(cols[i].Flex) / float64(totalFlex)
		whole := int(exact)
		widths[i] += whole
		distributed += whole
		shares = append(shares, share{idx: i, frac: exact - float64(whole)})
	}

	leftover := remaining - distributed
	sort.Slice(shares, func(a, b int) bool {
		if shares[a].frac != shares[b].frac {
			return shares[a].frac > shares[b].frac
		}
		return shares[a].idx < shares[b].idx // deterministic tie-break
	})
	for k := 0; k < leftover && k < len(shares); k++ {
		widths[shares[k].idx]++
	}

	return widths
}
