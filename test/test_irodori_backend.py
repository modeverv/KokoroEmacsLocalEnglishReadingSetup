"""Verify local reference selection, speed semantics, and usable WAV output."""
import io
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import wave

import numpy as np
import irodori_backend as backend


class IrodoriMLXTests(unittest.TestCase):
    def test_local_reference_speed_and_all_chunks(self):
        model = Mock()
        model.generate.return_value = [
            SimpleNamespace(audio=np.zeros(240), sample_rate=24000),
            SimpleNamespace(audio=np.ones(120) * 0.1, sample_rate=24000),
        ]
        with patch.object(backend, 'ensure_model', return_value=model), patch.object(backend.Path, 'is_file', return_value=True):
            wav = backend.synthesize('「日本語です。」次の文です。」', 'asuka', 2.0)
        kwargs = model.generate.call_args.kwargs
        self.assertEqual(kwargs['text'], '「日本語です。」次の文です。」')
        self.assertEqual(kwargs['ref_audio'], str(backend.ROOT / 'assets/asuka.wav'))
        self.assertEqual(kwargs['duration_scale'], 0.5)
        with wave.open(io.BytesIO(wav)) as audio:
            self.assertEqual(audio.getnframes(), 360)
            self.assertEqual(audio.getframerate(), 24000)

    def test_missing_reference_fails_before_loading_model(self):
        with patch.object(backend.Path, 'is_file', return_value=False), patch.object(backend, 'ensure_model') as load:
            with self.assertRaises(FileNotFoundError):
                backend.synthesize('日本語です。', 'asuka', 1)
            load.assert_not_called()

    def test_empty_generation_cannot_be_played(self):
        model = Mock()
        model.generate.return_value = []
        with patch.object(backend, 'ensure_model', return_value=model), patch.object(backend.Path, 'is_file', return_value=True):
            with self.assertRaisesRegex(RuntimeError, 'no audio'):
                backend.synthesize('日本語です。', 'asuka', 1)

    def test_unknown_voice_does_not_load_model(self):
        with patch.object(backend, 'ensure_model') as load:
            with self.assertRaises(ValueError):
                backend.synthesize('日本語です。', 'unknown', 1)
            load.assert_not_called()


if __name__ == '__main__':
    unittest.main()
