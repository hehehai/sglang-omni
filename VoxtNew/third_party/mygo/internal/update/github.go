package update

import (
	"context"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strconv"
	"strings"
)

// Updates published as GitHub releases in a repository whose latest
// release may be another's, such as a CLI's beside the app, have a feed
// that names the manifest in the release of a version,
//
//	https://github.com/<owner>/<repo>/releases/download/<prefix>{version}/update-<target>.json
//
// and ResolveFeed finds the newest release tagged <prefix> through the
// GitHub API. Other feeds are the URL of the manifest. Apps that take
// prereleases resolve either feed of GitHub releases through the API
// (ResolvePrereleaseFeed).

// VersionPlaceholder stands for the version in the feed of tagged releases.
const VersionPlaceholder = "{version}"

// ErrNotPublished is returned by ResolveFeed and ResolvePrereleaseFeed
// when no release is tagged with the prefix of the feed.
var ErrNotPublished = errors.New("no release is published")

// Getter gets a URL and returns the body of a successful response.
type Getter func(ctx context.Context, url string) (io.ReadCloser, error)

// GitHubAPI is the GitHub REST API, which tests replace.
var GitHubAPI = "https://api.github.com"

// Pages of releases that ResolveFeed reads at most, of releasesPerPage.
const (
	releasesPerPage = 100
	maxReleasePages = 10
)

// TaggedFeed returns the feed of the manifest name in the newest release of
// the GitHub repository repo ("owner/name") tagged prefix and a version.
func TaggedFeed(repo, prefix, name string) string {
	return "https://github.com/" + repo + "/releases/download/" + url.PathEscape(prefix) + VersionPlaceholder + "/" + url.PathEscape(name)
}

// ResolveFeed returns the URL of the manifest that feed names: feed itself,
// or for a feed of tagged releases (TaggedFeed) the manifest of the newest
// release with the tag's prefix that is neither a draft nor a prerelease,
// as the GitHub API lists them, newest first.
func ResolveFeed(ctx context.Context, feed string, get Getter) (string, error) {
	if !strings.Contains(feed, VersionPlaceholder) {
		return feed, nil
	}
	repo, prefix, err := parseTaggedFeed(feed)
	if err != nil {
		return "", err
	}
	tag, err := latestTagged(ctx, get, repo, prefix)
	if err != nil {
		return "", err
	}
	return strings.Replace(feed, "/"+url.PathEscape(prefix)+VersionPlaceholder+"/", "/"+url.PathEscape(tag)+"/", 1), nil
}

// parseTaggedFeed returns the repository and the tag prefix of a feed of
// tagged releases.
func parseTaggedFeed(feed string) (repo, prefix string, err error) {
	rest, ok := strings.CutPrefix(feed, "https://github.com/")
	parts := strings.SplitN(rest, "/", 6)
	if !ok || len(parts) != 6 || parts[2] != "releases" || parts[3] != "download" || !strings.HasSuffix(parts[4], VersionPlaceholder) {
		return "", "", fmt.Errorf("%s is not a feed of GitHub releases", feed)
	}
	prefix, err = url.PathUnescape(strings.TrimSuffix(parts[4], VersionPlaceholder))
	if err != nil {
		return "", "", fmt.Errorf("%s is not a feed of GitHub releases: %w", feed, err)
	}
	return parts[0] + "/" + parts[1], prefix, nil
}

// latestTagged returns the tag of the newest release of repo tagged
// prefix that is neither a draft nor a prerelease.
func latestTagged(ctx context.Context, get Getter, repo, prefix string) (string, error) {
	return newestTagged(ctx, get, repo, prefix, false)
}

// newestTagged returns the tag of the newest release of repo tagged prefix
// that is not a draft, and with prereleases unset, not a prerelease: the
// first in the API's order (newest first), or with prereleases the
// highest version (Compare) of the first page that has one, so that a
// stable fix published after a prerelease of a later version does not
// hide the prerelease.
func newestTagged(ctx context.Context, get Getter, repo, prefix string, prereleases bool) (string, error) {
	for page := 1; page <= maxReleasePages; page++ {
		u := GitHubAPI + "/repos/" + repo + "/releases?per_page=" + strconv.Itoa(releasesPerPage) + "&page=" + strconv.Itoa(page)
		releases, err := getReleases(ctx, get, u)
		if err != nil {
			return "", err
		}
		best := ""
		for _, r := range releases {
			if r.Draft || r.Prerelease && !prereleases || !strings.HasPrefix(r.TagName, prefix) {
				continue
			}
			if !prereleases {
				return r.TagName, nil
			}
			if best == "" || Compare(strings.TrimPrefix(r.TagName, prefix), strings.TrimPrefix(best, prefix)) > 0 {
				best = r.TagName
			}
		}
		if best != "" {
			return best, nil
		}
		if len(releases) < releasesPerPage {
			break
		}
	}
	return "", fmt.Errorf("%w in %s tagged %s", ErrNotPublished, repo, prefix)
}

// LatestFeed reports whether feed is the manifest name of the latest
// release of a GitHub repository,
//
//	https://github.com/<owner>/<repo>/releases/latest/download/<name>
//
// and returns the repository.
func LatestFeed(feed string) (repo, name string, ok bool) {
	rest, ok := strings.CutPrefix(feed, "https://github.com/")
	parts := strings.SplitN(rest, "/", 6)
	if !ok || len(parts) != 6 || parts[2] != "releases" || parts[3] != "latest" || parts[4] != "download" || parts[5] == "" {
		return "", "", false
	}
	return parts[0] + "/" + parts[1], parts[5], true
}

// ResolvePrereleaseFeed is ResolveFeed for apps that take prereleases
// (Updater.SetPrereleases): for a feed of GitHub releases, the latest
// release's (LatestFeed, whose tags are "v" and a version) or tagged ones'
// (TaggedFeed), it returns the manifest in the release of the highest
// version that is not a draft, prereleases included, through the GitHub
// API. Other feeds have no prereleases: it returns them as they are.
func ResolvePrereleaseFeed(ctx context.Context, feed string, get Getter) (string, error) {
	var repo, prefix, name string
	if r, n, ok := LatestFeed(feed); ok {
		repo, prefix, name = r, "v", n
	} else if strings.Contains(feed, VersionPlaceholder) {
		var err error
		if repo, prefix, err = parseTaggedFeed(feed); err != nil {
			return "", err
		}
		name = feed[strings.LastIndex(feed, "/")+1:]
	} else {
		return feed, nil
	}
	tag, err := newestTagged(ctx, get, repo, prefix, true)
	if err != nil {
		return "", err
	}
	return "https://github.com/" + repo + "/releases/download/" + url.PathEscape(tag) + "/" + name, nil
}

type release struct {
	TagName    string `json:"tag_name"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
}

func getReleases(ctx context.Context, get Getter, u string) ([]release, error) {
	body, err := get(ctx, u)
	if err != nil {
		return nil, err
	}
	defer body.Close()
	var releases []release
	// Release notes make a page large, but not this large.
	if err := json.UnmarshalRead(io.LimitReader(body, 64<<20), &releases); err != nil {
		return nil, fmt.Errorf("reading the releases of %s: %w", u, err)
	}
	return releases, nil
}
