"""Exercise OCR in the final Windows packages on a disposable hosted runner."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


def check_ocr(app_dir):
    print(f'Checking OCR in {app_dir.name}', flush=True)
    (app_dir / 'venera.exe').resolve(strict=True)
    library = (app_dir / 'venera_ocr.dll').resolve(strict=True)
    subprocess.run([
        'flutter.bat', 'test', '--no-pub', '--reporter', 'expanded',
        '--dart-define=VENERAX_TEST_OCR_NATIVE=true',
        f'--dart-define=VENERAX_TEST_OCR_LIBRARY={library}',
        'test/ocr_detector_preprocess_test.dart',
    ], check=True, timeout=300)


def main():
    archive, = Path('build/windows').resolve().glob('VeneraX-*-windows.zip')
    installer = archive.with_name(f'{archive.stem}-installer.exe')
    with tempfile.TemporaryDirectory(prefix='venerax-ocr-') as temporary:
        root = Path(temporary)
        portable = root / 'portable'
        with zipfile.ZipFile(archive) as package:
            package.extractall(portable)
        check_ocr(portable)

        installed = root / 'installed'
        subprocess.run([
            installer, '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
            '/CURRENTUSER', '/NOICONS', f'/DIR={installed}',
        ], check=True, timeout=300)
        check_ocr(installed)

        # Reproduce an installation from before the accelerator was shipped.
        (installed / 'venera_ocr.dll').unlink()
        updater = shutil.copyfile(installed / 'venera_updater.exe', root / 'updater.exe')
        print('Checking upgrade from an installation without the OCR library', flush=True)
        subprocess.run([
            updater, '--from-temp', '--app-dir', installed, '--package-file', archive,
        ], check=True, timeout=300)
        check_ocr(installed)


if __name__ == '__main__':
    main()
