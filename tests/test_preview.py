"""Offline tests for metadata previews and selectable playlist entries."""
import json
import os
import sys
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(__file__)), "app"))
import downloader


class PreviewTests(unittest.TestCase):
    def test_only_safe_remote_urls_are_accepted(self):
        for url in (None, '', 'file:///etc/passwd', 'data:text/plain,x', 'https://',
                    'https://example.org:999999/', 'https://example.org/\nother',
                    'https://example.org/' + 'a' * 9000):
            self.assertIsNone(downloader._safe_http_url(url), repr(url))
        self.assertEqual(downloader._safe_http_url('https://example.org/a?x=1'), 'https://example.org/a?x=1')

    def test_exact_format_ids_cannot_inject_selectors(self):
        self.assertEqual(downloader._selector('fmt:137'), '137')
        self.assertEqual(downloader._fragment_format('video', 'split:hls-1'), 'hls-1')
        self.assertNotEqual(downloader._selector('fmt:137+140'), '137+140')
        self.assertNotEqual(downloader._fragment_format('video', 'split:137/best'), '137/best')
        self.assertNotIn('+', downloader._selector('fmt:137+140'))

    def test_formats_are_actual_supported_choices_and_sizes_are_honest(self):
        info = {'formats': [
            {'format_id': '18', 'height': 360, 'fps': 30, 'ext': 'mp4', 'vcodec': 'avc1.42',
             'acodec': 'mp4a', 'filesize': 123},
            {'format_id': '137', 'height': 1080, 'fps': 30, 'ext': 'mp4', 'vcodec': 'avc1.64',
             'acodec': 'none', 'filesize_approx': 456},
            {'format_id': '140', 'ext': 'm4a', 'vcodec': 'none', 'acodec': 'mp4a'},
            {'format_id': 'bad+selector', 'height': 2160, 'ext': 'mp4', 'vcodec': 'avc1', 'acodec': 'mp4a'},
            {'format_id': 'webm', 'height': 720, 'ext': 'webm', 'vcodec': 'vp9', 'acodec': 'none'},
            {'format_id': 'nan', 'height': float('nan'), 'ext': 'mp4', 'vcodec': 'avc1', 'acodec': 'mp4a'},
        ]}
        choices = downloader._format_choices(info)
        self.assertEqual([c['height'] for c in choices], [1080, 360])
        self.assertEqual(choices[0]['quality'], 'split:137')
        self.assertEqual(choices[0]['size'], 456)
        self.assertTrue(choices[0]['estimated'])
        self.assertTrue(choices[0]['video_only'])
        self.assertEqual(choices[1]['quality'], 'fmt:18')
        self.assertEqual(choices[1]['size'], 123)
        self.assertFalse(choices[1]['video_only'])
        # A video-only choice without any audio stream is not offered as complete.
        self.assertEqual(downloader._format_choices({'formats': [info['formats'][1]]}), [])

    def test_playlist_caps_filters_and_deduplicates_without_downloading(self):
        options = []
        open_context = []
        items = [
            {'id': 'abcdefghijk', 'ie_key': 'Youtube', 'title': 'One', 'duration': 20},
            {'webpage_url': 'https://example.test/2', 'title': 'Two'},
            {'webpage_url': 'https://example.test/2', 'title': 'duplicate'},
            {'url': 'file:///secret', 'title': 'unsafe'},
        ] + [{'url': f'https://example.test/{i}', 'title': str(i)} for i in range(150)]
        class FakeYoutubeDL:
            def __init__(self, opts): options.append(opts)
            def __enter__(self): open_context.append(True); return self
            def __exit__(self, *args): open_context.pop(); return False
            def extract_info(self, url, download):
                assert download is False
                def entries():
                    for item in items:
                        assert open_context, 'lazy iterator must run while YoutubeDL is open'
                        yield item
                return {'_type': 'playlist', 'title': 'Playlist', 'entries': entries()}
        with mock.patch.dict(sys.modules, {'yt_dlp': types.SimpleNamespace(YoutubeDL=FakeYoutubeDL)}), \
             mock.patch.object(downloader, '_client_order', return_value=[None]):
            result = json.loads(downloader.inspect_playlist('https://example.test/list'))
        self.assertEqual(options[0]['playlistend'], 101)
        self.assertTrue(options[0]['extract_flat'])
        self.assertTrue(result['truncated'])
        self.assertLessEqual(len(result['entries']), 100)
        self.assertEqual(result['entries'][0]['url'], 'https://www.youtube.com/watch?v=abcdefghijk')
        urls = [r['url'] for r in result['entries']]
        self.assertEqual(len(urls), len(set(urls)))
        self.assertTrue(all(u.startswith('https://') for u in urls))
        self.assertEqual(result['entries'][0]['duration'], 20)

    def test_nonplaylist_and_empty_playlist_are_reported(self):
        with mock.patch.object(downloader, '_preview_info', return_value={'title': 'video'}):
            self.assertIn('error', json.loads(downloader.inspect_playlist('https://example.test/v')))
        with mock.patch.object(downloader, '_preview_info', return_value={'entries': [{'url': 'file:///x'}]}):
            self.assertIn('error', json.loads(downloader.inspect_playlist('https://example.test/list')))

    def test_preview_failure_does_not_queue_anything(self):
        with mock.patch.object(downloader, '_preview_info', side_effect=ValueError('blocked')):
            self.assertEqual(json.loads(downloader.inspect_formats('https://example.test'))['error'], 'blocked')
            self.assertEqual(json.loads(downloader.inspect_playlist('https://example.test'))['error'], 'blocked')


if __name__ == '__main__':
    unittest.main()
