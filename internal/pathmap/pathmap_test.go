package pathmap

import (
	"errors"
	"testing"
)

func mustNew(t *testing.T, ms ...Mapping) *Mapper {
	t.Helper()
	m, err := New(ms)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return m
}

func TestMap(t *testing.T) {
	mp := mustNew(t,
		Mapping{ID: "m-root", SourceID: "plex1", Style: POSIX, SourcePrefix: "/volume1/media", TargetRoot: "/mnt/nas", Enabled: true},
		Mapping{ID: "m-tv", SourceID: "plex1", Style: POSIX, SourcePrefix: "/volume1/media/tv", TargetRoot: "/mnt/nas-tv", Enabled: true},
		Mapping{ID: "m-off", SourceID: "plex1", Style: POSIX, SourcePrefix: "/volume1/media/movies", TargetRoot: "/mnt/elsewhere", Enabled: false},
		Mapping{ID: "w-drive", SourceID: "plexwin", Style: Windows, SourcePrefix: `D:\Media`, TargetRoot: "/mnt/nas", Enabled: true},
		Mapping{ID: "w-unc", SourceID: "plexwin", Style: Windows, SourcePrefix: `\\NAS\share\Video`, TargetRoot: "/mnt/video", Enabled: true},
		Mapping{ID: "other-src", SourceID: "plex2", Style: POSIX, SourcePrefix: "/data", TargetRoot: "/mnt/plex2", Enabled: true},
	)

	tests := []struct {
		name, src, in string
		want, wantID  string
		wantErr       error
	}{
		{"longest prefix wins", "plex1", "/volume1/media/tv/Futurama/Season 2/episode 03.MKV", "/mnt/nas-tv/Futurama/Season 2/episode 03.MKV", "m-tv", nil},
		{"shorter prefix fallback", "plex1", "/volume1/media/movies/Film (1999)/Film.mkv", "/mnt/nas/movies/Film (1999)/Film.mkv", "m-root", nil},
		{"disabled mapping ignored", "plex1", "/volume1/media/movies/x.mkv", "/mnt/nas/movies/x.mkv", "m-root", nil},
		{"component boundary, not string prefix", "plex1", "/volume1/media-old/x.mkv", "", "", ErrNoMapping},
		{"component boundary tv vs tvshows", "plex1", "/volume1/media/tvshows/x.mkv", "/mnt/nas/tvshows/x.mkv", "m-root", nil},
		{"duplicate and trailing slashes collapse", "plex1", "//volume1//media/tv//Show/ep.mkv", "/mnt/nas-tv/Show/ep.mkv", "m-tv", nil},
		{"unicode and case preserved", "plex1", "/volume1/media/tv/Café Ünïcode/Épisode – 01.MKV", "/mnt/nas-tv/Café Ünïcode/Épisode – 01.MKV", "m-tv", nil},
		{"posix prefix is case-sensitive", "plex1", "/Volume1/media/tv/x.mkv", "", "", ErrNoMapping},
		{"dotdot rejected not resolved", "plex1", "/volume1/media/tv/../../etc/passwd", "", "", ErrInvalidPath},
		{"dot rejected", "plex1", "/volume1/media/./tv/x.mkv", "", "", ErrInvalidPath},
		{"relative rejected", "plex1", "volume1/media/tv/x.mkv", "", "", ErrInvalidPath},
		{"NUL rejected", "plex1", "/volume1/media/tv/x\x00.mkv", "", "", ErrInvalidPath},
		{"mapping root itself rejected", "plex1", "/volume1/media/tv", "", "", ErrInvalidPath},
		{"source scoping", "plex2", "/volume1/media/tv/x.mkv", "", "", ErrNoMapping},
		{"other source maps", "plex2", "/data/movies/x.mkv", "/mnt/plex2/movies/x.mkv", "other-src", nil},
		{"windows drive, mixed separators, case-insensitive prefix", "plexwin", `d:/media\TV\Show\S01E01.mkv`, "/mnt/nas/TV/Show/S01E01.mkv", "w-drive", nil},
		{"windows UNC, case-insensitive server/share", "plexwin", `\\nas\SHARE\video\Movie\m.mp4`, "/mnt/video/Movie/m.mp4", "w-unc", nil},
		{"windows dotdot rejected", "plexwin", `D:\Media\..\Windows\x.mkv`, "", "", ErrInvalidPath},
		{"windows relative rejected", "plexwin", `Media\x.mkv`, "", "", ErrInvalidPath},
		{"windows other drive no mapping", "plexwin", `E:\Media\x.mkv`, "", "", ErrNoMapping},
		{"posix path against windows source", "plexwin", "/volume1/media/x.mkv", "", "", ErrInvalidPath},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := mp.Map(tc.src, tc.in)
			if tc.wantErr != nil {
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("Map(%q) err = %v, want %v", tc.in, err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Map(%q) unexpected err: %v", tc.in, err)
			}
			if got.Path != tc.want || got.MappingID != tc.wantID {
				t.Fatalf("Map(%q) = %q via %s, want %q via %s", tc.in, got.Path, got.MappingID, tc.want, tc.wantID)
			}
		})
	}
}

func TestNewRejects(t *testing.T) {
	tests := []struct {
		name string
		ms   []Mapping
		want error
	}{
		{"duplicate prefix same source", []Mapping{
			{ID: "a", SourceID: "s", Style: POSIX, SourcePrefix: "/media/", TargetRoot: "/mnt/a", Enabled: true},
			{ID: "b", SourceID: "s", Style: POSIX, SourcePrefix: "//media", TargetRoot: "/mnt/b", Enabled: true},
		}, ErrAmbiguous},
		{"windows duplicate differing only by case", []Mapping{
			{ID: "a", SourceID: "s", Style: Windows, SourcePrefix: `D:\Media`, TargetRoot: "/mnt/a", Enabled: true},
			{ID: "b", SourceID: "s", Style: Windows, SourcePrefix: `d:\MEDIA\`, TargetRoot: "/mnt/a", Enabled: true},
		}, ErrAmbiguous},
		{"target root slash", []Mapping{{ID: "a", SourceID: "s", Style: POSIX, SourcePrefix: "/m", TargetRoot: "/", Enabled: true}}, ErrInvalidMap},
		{"target relative", []Mapping{{ID: "a", SourceID: "s", Style: POSIX, SourcePrefix: "/m", TargetRoot: "mnt/nas", Enabled: true}}, ErrInvalidMap},
		{"target traversal", []Mapping{{ID: "a", SourceID: "s", Style: POSIX, SourcePrefix: "/m", TargetRoot: "/mnt/../etc", Enabled: true}}, ErrInvalidMap},
		{"bad style", []Mapping{{ID: "a", SourceID: "s", Style: "smb", SourcePrefix: "/m", TargetRoot: "/mnt", Enabled: true}}, ErrInvalidMap},
		{"bad UNC", []Mapping{{ID: "a", SourceID: "s", Style: Windows, SourcePrefix: `\\server`, TargetRoot: "/mnt", Enabled: true}}, ErrInvalidMap},
		{"missing id", []Mapping{{SourceID: "s", Style: POSIX, SourcePrefix: "/m", TargetRoot: "/mnt", Enabled: true}}, ErrInvalidMap},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := New(tc.ms); !errors.Is(err, tc.want) {
				t.Fatalf("New err = %v, want %v", err, tc.want)
			}
		})
	}
	// same prefix on different sources is fine
	if _, err := New([]Mapping{
		{ID: "a", SourceID: "s1", Style: POSIX, SourcePrefix: "/media", TargetRoot: "/mnt/a", Enabled: true},
		{ID: "b", SourceID: "s2", Style: POSIX, SourcePrefix: "/media", TargetRoot: "/mnt/b", Enabled: true},
	}); err != nil {
		t.Fatalf("same prefix across sources: %v", err)
	}
}

func FuzzMapNeverEscapes(f *testing.F) {
	mp, _ := New([]Mapping{
		{ID: "p", SourceID: "s", Style: POSIX, SourcePrefix: "/volume1/media", TargetRoot: "/mnt/nas", Enabled: true},
		{ID: "w", SourceID: "w", Style: Windows, SourcePrefix: `D:\Media`, TargetRoot: "/mnt/win", Enabled: true},
	})
	for _, s := range []string{"/volume1/media/a/b.mkv", "/volume1/media/../x", `D:\Media\a\..\..\b`, "/volume1/media//./a", `D:\Media/x\y.mkv`} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		for _, src := range []string{"s", "w"} {
			r, err := mp.Map(src, in)
			if err != nil {
				continue
			}
			root := map[string]string{"s": "/mnt/nas/", "w": "/mnt/win/"}[src]
			if len(r.Path) <= len(root) || r.Path[:len(root)] != root {
				t.Fatalf("escaped root: %q -> %q", in, r.Path)
			}
			for _, c := range r.Relative {
				if c == "" || c == "." || c == ".." {
					t.Fatalf("bad component %q in %q", c, r.Path)
				}
			}
		}
	})
}
