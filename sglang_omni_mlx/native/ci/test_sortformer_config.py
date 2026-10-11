# SPDX-License-Identifier: Apache-2.0
"""Exercise real checkpoint parsing before native allocation, plus legacy defaults."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from sglang_omni_mlx.native.ci import test_native_core

abi_build = test_native_core.abi_build

INTEGER_FIELDS = {
    "": {"num_speakers": 4},
    "fc_encoder_config": {
        "hidden_size": 512,
        "num_hidden_layers": 18,
        "num_attention_heads": 8,
        "intermediate_size": 2048,
        "num_mel_bins": 80,
        "conv_kernel_size": 9,
        "subsampling_factor": 8,
        "subsampling_conv_channels": 256,
        "subsampling_conv_kernel_size": 3,
        "subsampling_conv_stride": 2,
    },
    "tf_encoder_config": {
        "d_model": 192,
        "encoder_layers": 18,
        "encoder_attention_heads": 8,
        "encoder_ffn_dim": 768,
        "max_source_positions": 1500,
    },
    "modules_config": {
        "num_speakers": 4,
        "fc_d_model": 512,
        "tf_d_model": 192,
        "subsampling_factor": 8,
        "chunk_len": 188,
        "fifo_len": 0,
        "spkcache_len": 188,
        "spkcache_update_period": 188,
        "chunk_left_context": 1,
        "chunk_right_context": 1,
        "spkcache_sil_frames_per_spk": 5,
        "max_index": 10000,
    },
    "processor_config": {
        "feature_size": 80,
        "sampling_rate": 16000,
        "hop_length": 160,
        "n_fft": 512,
        "win_length": 400,
    },
}
FLOAT_FIELDS = {
    "tf_encoder_config": {"layer_norm_eps": 1e-5},
    "modules_config": {
        "pred_score_threshold": 1e-6,
        "scores_boost_latest": 0.5,
        "sil_threshold": 0.1,
        "strong_boost_rate": 0.3,
        "weak_boost_rate": 0.7,
        "min_pos_scores_rate": 0.5,
    },
    "processor_config": {"preemphasis": 0.97},
}
BOOLEAN_FIELDS = {
    "fc_encoder_config": {"attention_bias": True, "scale_input": True},
    "tf_encoder_config": {"k_proj_bias": False},
    "modules_config": {"use_aosc": True},
}
INVALID_CONFIG_VALUES = [
    (section, field, token)
    for fields, tokens in (
        (
            INTEGER_FIELDS,
            (
                "-1",
                "2147483648",
                "-2147483649",
                "4294967808",
                "-4294966784",
                "18446744073709551615",
                "-9223372036854775809",
                "1e100",
                "-1e100",
                "512.0",
                "16000.75",
                "5.12e2",
                "true",
                "false",
                '"512"',
                "null",
                "[]",
                "{}",
                "NaN",
                "Infinity",
                "-Infinity",
                "1e400",
                "-1e400",
            ),
        ),
        (
            FLOAT_FIELDS,
            (
                "-1",
                "1e100",
                "-1e100",
                "1e400",
                "-1e400",
                "NaN",
                "Infinity",
                "-Infinity",
                "true",
                "false",
                '"0.5"',
                "null",
                "[]",
                "{}",
                "4.00000001",
            ),
        ),
        (
            BOOLEAN_FIELDS,
            (
                "0",
                "1",
                "1.0",
                "1e100",
                "-1",
                "null",
                '"true"',
                "{}",
                "[]",
                "NaN",
                "Infinity",
            ),
        ),
    )
    for section, defaults in fields.items()
    for field in defaults
    for token in tokens
]


def config_text(section: str, field: str, token: str) -> str:
    property_json = f"{json.dumps(field)}:{token}"
    if section:
        aosc = '"use_aosc":true,' if field != "use_aosc" else ""
        property_json = f"{json.dumps(section)}:{{{aosc}{property_json}}}"
    else:
        pass
    return '{"use_aosc":true,' + property_json + "}"


def check_native_config(abi_build: Path, directory: Path, accepted: bool) -> None:
    case = "sortformer_config_accepted" if accepted else "sortformer_config_rejected"
    completed = subprocess.run(
        [str(abi_build / "abi_cases"), case],
        cwd=directory,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert completed.stderr == ""


@pytest.mark.parametrize("section,field,token", INVALID_CONFIG_VALUES)
def test_real_config_rejected_before_model_allocation(
    abi_build: Path, tmp_path: Path, section: str, field: str, token: str
) -> None:
    (tmp_path / "config.json").write_text(config_text(section, field, token))
    check_native_config(abi_build, tmp_path, accepted=False)


@pytest.mark.parametrize("section", ("", *tuple(INTEGER_FIELDS)[1:]))
@pytest.mark.parametrize("token", ("null", "[]", "0", "true", '"PRIVATE/model"'))
def test_real_config_invalid_sections(
    abi_build: Path, tmp_path: Path, section: str, token: str
) -> None:
    contents = config_text("", section, token) if section else token
    (tmp_path / "config.json").write_text(contents)
    check_native_config(abi_build, tmp_path, accepted=False)


def test_real_config_missing_file(abi_build: Path, tmp_path: Path) -> None:
    check_native_config(abi_build, tmp_path, accepted=False)


@pytest.mark.parametrize(
    "section,field,token",
    [
        ("tf_encoder_config", "layer_norm_eps", "1e-100"),
        ("modules_config", "pred_score_threshold", "1e-100"),
        ("modules_config", "use_aosc", "false"),
        *[
            (section, field, "1.00000001")
            for section, fields in FLOAT_FIELDS.items()
            for field in fields
            if field != "sil_threshold"
        ],
        *[
            (section, field, "2147483647")
            for section, fields in INTEGER_FIELDS.items()
            for field in fields
            if field != "max_index"
        ],
    ],
)
def test_real_config_device_arithmetic_bounds(
    abi_build: Path, tmp_path: Path, section: str, field: str, token: str
) -> None:
    (tmp_path / "config.json").write_text(config_text(section, field, token))
    check_native_config(abi_build, tmp_path, accepted=False)


@pytest.mark.parametrize(
    "contents",
    (
        '{"use_aosc":true}',
        '{"use_aosc":true,"fc_encoder_config":{},"tf_encoder_config":{},'
        '"processor_config":{},"modules_config":{"use_aosc":true}}',
        '{"use_aosc":true,"hidden_size":999,"sampling_rate":8000,'
        '"fc_encoder_config":{},"processor_config":{},"unknown":"ignored"}',
    ),
)
def test_real_config_legacy_defaults_and_section_fallback(
    abi_build: Path, tmp_path: Path, contents: str
) -> None:
    (tmp_path / "config.json").write_text(contents)
    outputs = []
    for mode in ("legacy", "strict"):
        completed = subprocess.run(
            [str(abi_build / "config_cases"), mode],
            cwd=tmp_path,
            capture_output=True,
            text=True,
            timeout=15,
            check=True,
        )
        assert completed.stderr == ""
        parsed = json.loads(completed.stdout)
        for fields in (INTEGER_FIELDS, FLOAT_FIELDS, BOOLEAN_FIELDS):
            for section, defaults in fields.items():
                for field, default in defaults.items():
                    actual = parsed[section][field] if section else parsed[field]
                    assert actual == pytest.approx(default, rel=1e-7)
        outputs.append(completed.stdout)
    assert outputs[0] == outputs[1]
    check_native_config(abi_build, tmp_path, accepted=True)


@pytest.mark.parametrize(
    "section,field,default",
    [
        (section, field, default)
        for section, fields in INTEGER_FIELDS.items()
        for field, default in fields.items()
    ],
)
def test_real_legacy_fraction_truncation_native_rejection(
    abi_build: Path, tmp_path: Path, section: str, field: str, default: int
) -> None:
    (tmp_path / "config.json").write_text(
        config_text(section, field, str(default + 0.75))
    )
    completed = subprocess.run(
        [str(abi_build / "config_cases"), "legacy"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=15,
        check=True,
    )
    assert completed.stderr == ""
    parsed = json.loads(completed.stdout)
    assert (parsed[section][field] if section else parsed[field]) == default
    check_native_config(abi_build, tmp_path, accepted=False)


@pytest.mark.parametrize(
    "section,field,default",
    [
        (section, field, default)
        for section, fields in INTEGER_FIELDS.items()
        for field, default in fields.items()
    ],
)
@pytest.mark.parametrize("offset", (4294967296, -4294967296))
def test_real_integer_wrapping_is_rejected_in_both_modes(
    abi_build: Path,
    tmp_path: Path,
    section: str,
    field: str,
    default: int,
    offset: int,
) -> None:
    (tmp_path / "config.json").write_text(
        config_text(section, field, str(default + offset))
    )
    for mode in ("legacy", "strict"):
        completed = subprocess.run(
            [str(abi_build / "config_cases"), mode],
            cwd=tmp_path,
            capture_output=True,
            text=True,
            timeout=15,
        )
        assert completed.returncode == 1
        assert completed.stderr == "Invalid configuration.\n"
    check_native_config(abi_build, tmp_path, accepted=False)


@pytest.mark.parametrize(
    "section,field",
    [
        (section, field)
        for fields in (INTEGER_FIELDS, FLOAT_FIELDS)
        for section, defaults in fields.items()
        for field in defaults
    ],
)
@pytest.mark.parametrize("token", ("1e100", "-1e100", "1e400", "NaN", "Infinity"))
def test_real_legacy_unsafe_conversion_is_safe_error(
    abi_build: Path, tmp_path: Path, section: str, field: str, token: str
) -> None:
    (tmp_path / "config.json").write_text(config_text(section, field, token))
    completed = subprocess.run(
        [str(abi_build / "config_cases"), "legacy"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert completed.returncode == 1
    assert completed.stderr == "Invalid configuration.\n"
