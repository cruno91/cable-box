// Package pathmap translates media paths as reported by Plex into paths under
// the Pi's read-only NAS mount roots.
//
// Rules:
//   - Prefixes match on complete path components, longest match wins, and
//     equal-length matches with different targets are rejected as ambiguous.
//   - Plex paths may be POSIX or Windows (drive or UNC); each style is parsed
//     by its own rules, never by the host's path/filepath semantics.
//   - Relative paths, NUL bytes and "."/".." components are rejected, never
//     resolved. The remainder's case and Unicode bytes are preserved.
//
// This package is pure: it never touches the filesystem. Whether the mapped
// file exists, is a regular file, and canonicalises beneath an allowlisted
// mounted root is checked on the Pi by the worker.
package pathmap

import (
	"errors"
	"fmt"
	"sort"
	"strings"
)

// Style is the path syntax of a mapping's source prefix.
type Style string

const (
	POSIX   Style = "posix"
	Windows Style = "windows"
)

// Mapping maps one source prefix (as Plex reports it) to a POSIX root on the Pi.
type Mapping struct {
	ID           string
	SourceID     string // Plex source this mapping belongs to
	Style        Style
	SourcePrefix string // e.g. "/volume1/media" or `\\nas\media` or `D:\Media`
	TargetRoot   string // absolute POSIX path on the Pi, e.g. "/mnt/nas"
	Enabled      bool
}

// Result is a successful translation.
type Result struct {
	MappingID string
	Path      string // absolute POSIX path under the mapping's TargetRoot
	Relative  []string
}

var (
	ErrInvalidPath = errors.New("invalid path")
	ErrNoMapping   = errors.New("no mapping matches path")
	ErrAmbiguous   = errors.New("ambiguous mapping")
	ErrInvalidMap  = errors.New("invalid mapping")
)

// parsed is a path split into a comparable root and components.
type parsed struct {
	root  string   // "/" for POSIX; "c:" / `\\server\share` (lowercased) for Windows
	parts []string // components, original case preserved
	style Style
}

func parse(style Style, p string) (parsed, error) {
	if p == "" {
		return parsed{}, fmt.Errorf("%w: empty", ErrInvalidPath)
	}
	if strings.ContainsRune(p, 0) {
		return parsed{}, fmt.Errorf("%w: contains NUL", ErrInvalidPath)
	}
	switch style {
	case POSIX:
		if !strings.HasPrefix(p, "/") {
			return parsed{}, fmt.Errorf("%w: not absolute: %q", ErrInvalidPath, p)
		}
		parts, err := components(strings.Split(p, "/"))
		if err != nil {
			return parsed{}, err
		}
		return parsed{root: "/", parts: parts, style: POSIX}, nil
	case Windows:
		q := strings.ReplaceAll(p, "/", `\`)
		switch {
		case strings.HasPrefix(q, `\\`):
			// UNC: \\server\share\rest...
			segs := strings.Split(q[2:], `\`)
			if len(segs) < 2 || segs[0] == "" || segs[1] == "" || segs[0] == "?" || segs[0] == "." {
				return parsed{}, fmt.Errorf("%w: bad UNC path %q", ErrInvalidPath, p)
			}
			parts, err := components(segs[2:])
			if err != nil {
				return parsed{}, err
			}
			root := `\\` + strings.ToLower(segs[0]) + `\` + strings.ToLower(segs[1])
			return parsed{root: root, parts: parts, style: Windows}, nil
		case len(q) >= 3 && isDriveLetter(q[0]) && q[1] == ':' && q[2] == '\\':
			parts, err := components(strings.Split(q[3:], `\`))
			if err != nil {
				return parsed{}, err
			}
			return parsed{root: strings.ToLower(q[:2]), parts: parts, style: Windows}, nil
		default:
			return parsed{}, fmt.Errorf("%w: not an absolute Windows path: %q", ErrInvalidPath, p)
		}
	default:
		return parsed{}, fmt.Errorf("%w: unknown style %q", ErrInvalidPath, style)
	}
}

func isDriveLetter(b byte) bool { return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') }

// components drops empty segments (duplicate or trailing separators) and
// rejects dot segments rather than resolving them.
func components(segs []string) ([]string, error) {
	out := make([]string, 0, len(segs))
	for _, s := range segs {
		switch s {
		case "":
			continue
		case ".", "..":
			return nil, fmt.Errorf("%w: dot segment %q", ErrInvalidPath, s)
		}
		out = append(out, s)
	}
	return out, nil
}

// eqComponent compares components: exact for POSIX, case-insensitive for
// Windows (NTFS/SMB semantics).
func eqComponent(style Style, a, b string) bool {
	if style == Windows {
		return strings.EqualFold(a, b)
	}
	return a == b
}

func (p parsed) hasPrefix(pre parsed) bool {
	if p.style != pre.style || p.root != pre.root || len(pre.parts) > len(p.parts) {
		return false
	}
	for i := range pre.parts {
		if !eqComponent(p.style, p.parts[i], pre.parts[i]) {
			return false
		}
	}
	return true
}

// key is a canonical form used to detect duplicate prefixes.
func (p parsed) key() string {
	parts := p.parts
	if p.style == Windows {
		parts = make([]string, len(p.parts))
		for i, s := range p.parts {
			parts[i] = strings.ToLower(s)
		}
	}
	return string(p.style) + "|" + p.root + "|" + strings.Join(parts, "\x00")
}

// Mapper is an immutable, validated set of mappings.
type Mapper struct {
	entries []entry
}

type entry struct {
	m      Mapping
	prefix parsed
	target []string
}

// New validates mappings and builds a Mapper. Disabled mappings are ignored.
// Two enabled mappings for the same source with the same normalized prefix
// are rejected outright, whether or not their targets agree.
func New(ms []Mapping) (*Mapper, error) {
	var es []entry
	seen := map[string]string{}
	for _, m := range ms {
		if !m.Enabled {
			continue
		}
		if m.ID == "" {
			return nil, fmt.Errorf("%w: missing id", ErrInvalidMap)
		}
		pre, err := parse(m.Style, m.SourcePrefix)
		if err != nil {
			return nil, fmt.Errorf("%w: mapping %s source prefix: %v", ErrInvalidMap, m.ID, err)
		}
		tgt, err := parse(POSIX, m.TargetRoot)
		if err != nil {
			return nil, fmt.Errorf("%w: mapping %s target root: %v", ErrInvalidMap, m.ID, err)
		}
		if len(tgt.parts) == 0 {
			return nil, fmt.Errorf("%w: mapping %s target root must not be /", ErrInvalidMap, m.ID)
		}
		k := m.SourceID + "#" + pre.key()
		if other, dup := seen[k]; dup {
			return nil, fmt.Errorf("%w: mappings %s and %s share source prefix %q", ErrAmbiguous, other, m.ID, m.SourcePrefix)
		}
		seen[k] = m.ID
		es = append(es, entry{m: m, prefix: pre, target: tgt.parts})
	}
	// longest prefix first; stable by ID for deterministic diagnostics
	sort.SliceStable(es, func(i, j int) bool {
		if len(es[i].prefix.parts) != len(es[j].prefix.parts) {
			return len(es[i].prefix.parts) > len(es[j].prefix.parts)
		}
		return es[i].m.ID < es[j].m.ID
	})
	return &Mapper{entries: es}, nil
}

// Map translates a Plex-reported path for the given source. The path's style
// is taken from the candidate mappings: a path is tried against each style
// present for that source.
func (mp *Mapper) Map(sourceID, plexPath string) (Result, error) {
	var best *entry
	var bestLen = -1
	var cache = map[Style]parsed{}
	var parseErr error
	for i := range mp.entries {
		e := &mp.entries[i]
		if e.m.SourceID != sourceID {
			continue
		}
		p, ok := cache[e.m.Style]
		if !ok {
			var err error
			p, err = parse(e.m.Style, plexPath)
			if err != nil {
				parseErr = err
				cache[e.m.Style] = parsed{style: "invalid"}
				continue
			}
			cache[e.m.Style] = p
		}
		if p.style != e.m.Style || !p.hasPrefix(e.prefix) {
			continue
		}
		n := len(e.prefix.parts)
		if n > bestLen {
			best, bestLen = e, n
		} else if n == bestLen && best != nil {
			// same length, different style or root can't both match; reaching
			// here means two styles matched the same input: refuse.
			return Result{}, fmt.Errorf("%w: %s and %s both match %q", ErrAmbiguous, best.m.ID, e.m.ID, plexPath)
		}
	}
	if best == nil {
		if parseErr != nil && len(cache) > 0 && allInvalid(cache) {
			return Result{}, parseErr
		}
		return Result{}, fmt.Errorf("%w: source %s path %q", ErrNoMapping, sourceID, plexPath)
	}
	p := cache[best.m.Style]
	rel := append([]string(nil), p.parts[len(best.prefix.parts):]...)
	if len(rel) == 0 {
		return Result{}, fmt.Errorf("%w: path is the mapping root itself: %q", ErrInvalidPath, plexPath)
	}
	for _, c := range rel {
		// a Windows component may legally contain '/'-free text only; a POSIX
		// target must not gain a separator from a Windows name.
		if strings.ContainsRune(c, '/') {
			return Result{}, fmt.Errorf("%w: component %q contains '/'", ErrInvalidPath, c)
		}
	}
	out := "/" + strings.Join(append(append([]string(nil), best.target...), rel...), "/")
	return Result{MappingID: best.m.ID, Path: out, Relative: rel}, nil
}

func allInvalid(c map[Style]parsed) bool {
	for _, p := range c {
		if p.style != "invalid" {
			return false
		}
	}
	return true
}
